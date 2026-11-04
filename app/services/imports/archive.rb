require "zip"

module Imports
  # Turns one upload (a certificate file or a zip) into candidate files, with the guards
  # PLAN.md requires ("Bulk import pipeline", step 2):
  #
  # - zips are read in place with rubyzip; nested zips are followed max_zip_depth levels
  #   below the upload, and a zip deeper than that is rejected unopened
  # - __MACOSX, .DS_Store, Thumbs.db, desktop.ini and hidden files are skipped (no item)
  # - entries named with "..", an absolute path or a drive letter (zip-slip) are rejected.
  #   Nothing is ever written to a path taken from an archive: each entry is streamed into
  #   a numbered file in dir
  # - zip-bomb guard: at most max_entries files, and max_uncompressed_bytes read out of
  #   zips, per Archive (one per batch). Bytes are counted as they are inflated, never
  #   taken from the size the header declares. Past a limit the entry is rejected and
  #   expansion stops (limit_message says where)
  # - and at most max_zip_records central-directory records across the batch's zips
  #   (default RECORDS_PER_ENTRY x max_entries), counting every record: folders, junk and
  #   nested zips too, which are not files. rubyzip loads a zip's whole central directory
  #   before the first entry can be looked at, so the record count the zip declares (read
  #   from its end records alone, Zip::File.count_entries) is checked against what is left
  #   before the zip is opened. A zip listing more is rejected unopened and expansion stops
  # - and, also before opening, the bytes rubyzip would hold for those end records and that
  #   directory (Directory reads the end record, or the Zip64 one, then walks the records'
  #   fixed headers without keeping them): a Zip64 end record must sit next to its locator
  #   (rubyzip reads everything between them), and the directory may take at most
  #   DIRECTORY_BYTES_PER_RECORD per declared record. Long names, extra fields or comments
  #   past that, a directory larger than its declared size allows, or one said to run past
  #   the end of the file: that zip alone is rejected unopened (a zip whose end records are
  #   cut short or apart is one that can't be read). Nested zips get the same checks, each
  #   when it is reached
  # - the type comes from the bytes (Marcel, plus the HEIC/HEIF brands), not the name.
  #   Anything but PDF, JPEG, PNG, HEIC/HEIF and WEBP is rejected
  #
  #   archive = Imports::Archive.new(dir)
  #   archive.expand(path, name: "crew.zip") do |entry|
  #     entry.rejected? ? reject(entry.name, entry.rejection_reason) : import(entry)
  #   end
  #   archive.entries_seen   # files examined (each yielded once); skipped junk excluded
  #   archive.zip_records    # central-directory records in the zips opened so far
  #   archive.skipped        # names of the junk files skipped (at most max_zip_records)
  #   archive.limit_message  # why expansion stopped early, or nil
  #
  # The block gets every file exactly once. entry.path is only valid inside the block:
  # files streamed out of a zip are deleted when it returns. Errors raised by the block
  # propagate; a zip that can't be read becomes one rejected entry, and a file in it that
  # can't be read another. rubyzip trips over some malformed structures (an extra field cut
  # short after its ID) with a plain Ruby error rather than a Zip::Error: those are rejected
  # the same way, and reported (Rails.error) so a new kind stays visible.
  class Archive
    # name: where the file came from, e.g. "crew.zip/cards/ortiz.jpg" (UTF-8, at most
    # MAX_NAME_LENGTH characters). path: the local copy (nil when rejected). sha256: hex
    # digest of the bytes (nil when rejected before they were read). from_zip: false when
    # the entry is the uploaded file itself.
    Entry = Data.define(:name, :path, :content_type, :byte_size, :sha256, :from_zip, :rejection_reason) do
      def rejected?
        !rejection_reason.nil?
      end

      def accepted?
        !rejected?
      end

      # "ortiz.jpg"
      def filename
        File.basename(name)
      end
    end

    JUNK_FILENAMES = %w[.ds_store thumbs.db desktop.ini].freeze
    JUNK_FOLDERS = %w[__macosx].freeze
    HEIC_BRANDS = %w[heic heix heim heis hevc hevx].freeze
    HEIF_BRANDS = %w[mif1 msf1].freeze
    AVIF_BRANDS = %w[avif avis].freeze
    CHUNK_SIZE = 64.kilobytes
    MAX_NAME_LENGTH = 255
    # Records a zip may hold per file allowed: room for folders and a __MACOSX twin of every
    # file (macOS Archive Utility), with plenty to spare. About 1 KB of memory per record.
    RECORDS_PER_ENTRY = 5
    # Directory bytes a zip may hold per record it declares: the 46-byte header, a long name, a
    # few extra fields (and the local extra field rubyzip reads with each) and a comment, with
    # plenty to spare: real zips use 100 to 300. At most 20 MB for a whole batch's records.
    DIRECTORY_BYTES_PER_RECORD = 2.kilobytes
    READ_ERRORS = [ Zip::Error, Zlib::Error, IOError, SystemCallError ].freeze

    class LimitReached < StandardError; end
    private_constant :LimitReached

    # A zip's central directory, sized the way rubyzip (3.x, Zip::CentralDirectory) reads it, so
    # the guard sees what rubyzip would load: the last end-of-central-directory record in the
    # file's tail (and the Zip64 end record it points to when its fields are maxed out) gives
    # the declared offset and size; then each of the declared records' fixed headers gives its
    # real length (rubyzip reads records one after another from the offset, whatever size was
    # declared), plus the local extra field rubyzip reads for each. Nothing is kept. Raises
    # Zip::Error when the end records are missing or cut short, or a Zip64 end record outside
    # the tail is more than ZIP64_EXTENSIBLE_LIMIT before its locator (new: rubyzip would read
    # the whole span), or the directory is said to run past the end of the file (bytes).
    class Directory
      END_SIGNATURE = [ 0x06054b50 ].pack("V").b
      ZIP64_END_SIGNATURE = [ 0x06064b50 ].pack("V").b
      ZIP64_LOCATOR_SIGNATURE = [ 0x07064b50 ].pack("V").b
      RECORD_SIGNATURE = 0x02014b50
      LOCAL_SIGNATURE = 0x04034b50
      END_LENGTH = 22
      ZIP64_END_LENGTH = 56
      ZIP64_LOCATOR_LENGTH = 20
      ZIP64_EXTENSIBLE_LIMIT = 64.kilobytes # data a Zip64 end record may carry past its 56 bytes; real zips have none
      TAIL_LENGTH = 0xFFFF + END_LENGTH + ZIP64_LOCATOR_LENGTH # the longest comment, as rubyzip reads it
      RECORD_LENGTH = 46
      LOCAL_LENGTH = 30
      ZIP64_EXTRA_ID = 0x0001
      MAX16 = 0xFFFF
      MAX32 = 0xFFFFFFFF

      attr_reader :offset, :declared_size

      def initialize(path)
        @path = path.to_s
        File.open(@path, "rb") do |io|
          @file_size = io.size
          read_end(io)
        end
      end

      # The bytes rubyzip would read for records records: the larger of the declared size and
      # the measured one. Stops counting once over limit.
      def bytes(records, limit:)
        raise Zip::Error, "its central directory is said to run past the end of the file" if offset + declared_size > @file_size
        return declared_size if declared_size > limit

        total = 0
        File.open(@path, "rb") do |io|
          position = offset
          records.times do
            length, local_offset = record_at(io, position)
            break unless length # rubyzip stops at the first record it can't read

            total += length + local_extra_length(io, local_offset)
            break if total > limit

            position += length
          end
        end
        [ total, declared_size ].max
      end

      private
        def read_end(io)
          start = [ @file_size - TAIL_LENGTH, 0 ].max
          io.seek(start)
          tail = io.read.to_s.b
          at = tail.rindex(END_SIGNATURE) or raise Zip::Error, "no end of central directory record"
          fields = tail.byteslice(at, END_LENGTH).unpack("VvvvvVVv")
          raise Zip::Error, "the end of central directory record is cut short" if fields.include?(nil)

          _, disk, directory_disk, disk_records, records, @declared_size, @offset = fields
          return unless [ disk, directory_disk, disk_records, records ].include?(MAX16) || [ @declared_size, @offset ].include?(MAX32)

          read_zip64_end(io, tail, at, start)
        end

        def read_zip64_end(io, tail, end_at, start)
          locator = tail.rindex(ZIP64_LOCATOR_SIGNATURE, end_at) or raise Zip::Error, "no Zip64 end of central directory locator"
          found = tail.rindex(ZIP64_END_SIGNATURE, locator)
          record = if found
            tail.byteslice(found, locator - found + 1) # rubyzip's slice, one byte into the locator
          else
            position = tail.byteslice(locator, ZIP64_LOCATOR_LENGTH).unpack("VVQ<V")[2]
            # rubyzip reads from position up to the locator into one String: there must be a whole
            # record there, and not much more (real zips put it right before the locator).
            raise Zip::Error, "the Zip64 end of central directory locator is cut short" unless position

            span = start + locator - position
            raise Zip::Error, "the Zip64 end of central directory record is cut short" if span < ZIP64_END_LENGTH
            raise Zip::Error, "the Zip64 end of central directory record is not next to its locator" if span > ZIP64_END_LENGTH + ZIP64_EXTENSIBLE_LIMIT

            io.seek(position)
            io.read(ZIP64_END_LENGTH).to_s.b
          end
          fields = record.byteslice(0, ZIP64_END_LENGTH).to_s.unpack("VQ<vvVVQ<Q<Q<Q<")
          raise Zip::Error, "the Zip64 end of central directory record is cut short" if fields.include?(nil)

          @declared_size, @offset = fields.last(2)
        end

        # [the record's length, the local header offset rubyzip will read], or nil when there
        # is no readable record at position.
        def record_at(io, position)
          return if position + RECORD_LENGTH > @file_size

          io.seek(position)
          header = io.read(RECORD_LENGTH).to_s.b
          fields = header.unpack("VCCvvvvvVVVvvvvvVV")
          return unless fields.first == RECORD_SIGNATURE

          compressed_size, size, name_length, extra_length, comment_length = fields.values_at(9..13)
          io.seek(position + RECORD_LENGTH + name_length)
          extra = io.read(extra_length).to_s.b
          [ RECORD_LENGTH + name_length + extra_length + comment_length, local_offset(extra, fields.last, size, compressed_size) ]
        end

        # Like rubyzip: with a Zip64 extra field the offset comes from it (only when the
        # header's is maxed out), else from the header.
        def local_offset(extra, header_offset, size, compressed_size)
          zip64 = zip64_extra(extra)
          return header_offset unless zip64
          return unless header_offset == MAX32

          skip = (size == MAX32 ? 8 : 0) + (compressed_size == MAX32 ? 8 : 0)
          zip64.byteslice(skip, 8)&.unpack1("Q<")
        end

        # The data of the record's last Zip64 extra field, or nil.
        def zip64_extra(extra)
          data = nil
          at = 0
          while at + 4 <= extra.bytesize
            id, length = extra.byteslice(at, 4).unpack("vv")
            data = extra.byteslice(at + 4, length).to_s if id == ZIP64_EXTRA_ID
            at += 4 + length
          end
          data
        end

        # The extra field length in the local header at local_offset, which rubyzip reads too.
        def local_extra_length(io, local_offset)
          return 0 if local_offset.nil? || local_offset + LOCAL_LENGTH > @file_size

          io.seek(local_offset)
          signature, *, extra_length = io.read(LOCAL_LENGTH).to_s.b.unpack("VvvvvvVVVvv")
          signature == LOCAL_SIGNATURE ? extra_length.to_i : 0
        end
    end
    private_constant :Directory

    attr_reader :entries_seen, :bytes_read, :zip_records, :skipped, :limit_message

    def initialize(dir, max_entries: Config.max_entries, max_uncompressed_bytes: Config.max_uncompressed_bytes,
      max_zip_depth: Config.max_zip_depth, max_zip_records: nil)
      @dir = Pathname(dir)
      @max_entries = max_entries
      @max_uncompressed_bytes = max_uncompressed_bytes
      @max_zip_depth = max_zip_depth
      @max_zip_records = max_zip_records || (max_entries * RECORDS_PER_ENTRY)
      @entries_seen = 0
      @bytes_read = 0
      @zip_records = 0
      @skipped = []
      @limit_message = nil
      @sequence = 0
    end

    class << self
      # The content type of the file at path, judged by its bytes. name only refines a
      # match (a zip named .docx is a Word file); it never turns unknown bytes into a PDF.
      def content_type_for(path, name: nil)
        File.open(path, "rb") do |file|
          head = file.read(1024).to_s.b
          heif = heif_type(head)
          next heif if heif

          file.rewind
          by_magic = Marcel::MimeType.for(file)
          next(head.include?("%PDF-") ? "application/pdf" : by_magic) if by_magic == Marcel::MimeType::BINARY

          file.rewind
          Marcel::MimeType.for(file, name: name.presence)
        end
      end

      # HEIC/HEIF photos are ISO-BMFF files that open with an "ftyp" box listing brands;
      # Marcel misses some iPhone ones (heix, msf1). AVIF shares the box and isn't supported.
      def heif_type(head)
        return unless head.bytesize >= 16 && head.byteslice(4, 4) == "ftyp"

        box_size = head.byteslice(0, 4).unpack1("N").clamp(16, head.bytesize)
        brands = [ head.byteslice(8, 4), *head.byteslice(16, box_size - 16).scan(/.{4}/m) ]
        return if brands.intersect?(AVIF_BRANDS)

        if brands.intersect?(HEIC_BRANDS) then "image/heic"
        elsif brands.intersect?(HEIF_BRANDS) then "image/heif"
        end
      end
    end

    def limit_reached?
      !@limit_message.nil?
    end

    # The rejection for an upload left unread because a limit already stopped the batch
    # (counted, so every upload is still accounted for).
    def not_examined(name)
      @entries_seen += 1
      rejected(clean_name(name), "Not imported: the batch had already stopped at a limit", from_zip: false)
    end

    # Yields an Entry for the upload at path, or one for each file inside it when it's a zip.
    def expand(path, name:, &block)
      name = clean_name(name)
      return skip(name) if junk?(name)
      return yield(not_examined(name)) if limit_reached?

      content_type = self.class.content_type_for(path, name: name)
      if Config.zip?(content_type)
        expand_zip(path, name, 0, &block)
      elsif (over_limit = count_entry(name))
        yield over_limit
      else
        yield file_entry(path, name, content_type, from_zip: false)
      end
    end

    private
      def expand_zip(path, chain, depth, &block)
        zip = open_zip(path, chain)
        return yield(zip) if zip.is_a?(Entry)

        zip.entries.each do |zip_entry|
          break if limit_reached?

          expand_zip_entry(zip_entry, chain, depth, &block)
        end
      end

      # The opened Zip::File, or the rejected Entry for the zip. The record count the zip
      # declares, and the bytes its directory takes, are checked before rubyzip loads that
      # directory. Directory reads the end record first: rubyzip's own reader crashes (not a
      # Zip::Error) on one that is cut short.
      def open_zip(path, name)
        directory = Directory.new(path)
        declared = Zip::File.count_entries(path.to_s) # reads the end records only, which Directory has sized
        return too_many_records(name, declared) if declared > @max_zip_records - @zip_records

        limit = declared * DIRECTORY_BYTES_PER_RECORD
        return oversized_directory(name, declared, limit) if directory.bytes(declared, limit: limit) > limit

        zip = Zip::File.open(path.to_s)
        @zip_records += declared
        zip
      rescue StandardError => error # nothing here yields, so no error of the caller's block passes through
        # Corrupt, truncated or not really a zip: the zip itself is one rejected file.
        report_unexpected(error)
        @entries_seen += 1
        rejected(name, "Couldn't open this zip (#{error_text(error)})")
      end

      def expand_zip_entry(zip_entry, chain, depth, &block)
        return if zip_entry.directory?

        raw_name = decode(zip_entry.name)
        name = clean_name("#{chain}/#{raw_name}")
        return skip(name) if !unsafe_path?(raw_name) && junk?(raw_name)
        over_limit = count_entry(name)
        return yield(over_limit) if over_limit
        return yield(rejected(name, "Unsafe path in zip (zip-slip guard): refused")) if unsafe_path?(raw_name)
        return yield(rejected(name, "Symbolic link in zip: refused")) if zip_entry.symlink?
        return yield(rejected(name, "Password-protected zip entry: can't be read")) if zip_entry.encrypted?

        path = next_path
        begin
          result = stream_out(zip_entry, name, path)
          return yield(result) if result.is_a?(Entry)

          byte_size, sha256 = result
          content_type = self.class.content_type_for(path, name: raw_name)
          if !Config.zip?(content_type)
            yield file_entry(path, name, content_type, byte_size: byte_size, sha256: sha256, from_zip: true)
          elsif depth >= @max_zip_depth
            yield rejected(name, "Zip nested more than #{@max_zip_depth} levels deep: not opened", sha256: sha256)
          else
            @entries_seen -= 1 # a nested zip is a folder, not a file: its contents are counted instead
            expand_zip(path, name, depth + 1, &block)
          end
        ensure
          FileUtils.rm_f(path)
        end
      end

      # Counts a file against max_entries and returns nil; past the limit, stops expansion
      # and returns the rejection for this file instead.
      def count_entry(name)
        if @entries_seen >= @max_entries
          limit = "#{number(@max_entries)}-file"
          @limit_message = "Stopped at the #{limit} limit for one batch: #{name} and anything after it were not imported."
          @entries_seen += 1
          return rejected(name, "Over the #{limit} limit for one batch: not imported")
        end

        @entries_seen += 1
        nil
      end

      # A zip listing more central-directory records than the batch has left: rejected
      # unopened, and expansion stops.
      def too_many_records(name, declared)
        limit = "#{number(@max_zip_records)}-entry zip"
        @limit_message = "Stopped at the #{limit} limit for one batch (zip-bomb guard): #{name} lists " \
                         "#{number(declared)} entries, so it and anything after it were not imported."
        @entries_seen += 1
        rejected(name, "This zip lists #{number(declared)} entries, over the #{limit} limit for one batch " \
                       "(zip-bomb guard): not opened")
      end

      # A zip whose list of files is bigger than its entries need: rejected unopened (just this
      # zip; expansion goes on).
      def oversized_directory(name, declared, limit)
        @entries_seen += 1
        size = ActiveSupport::NumberHelper.number_to_human_size(limit)
        rejected(name, "This zip's list of files is larger than #{size} for its #{number(declared)} " \
                       "#{"entry".pluralize(declared)} (zip-bomb guard): not opened")
      end

      # Inflates zip_entry into path, hashing as it goes. Returns [byte_size, sha256], or a
      # rejected Entry: past max_uncompressed_bytes (counting the bytes actually produced),
      # or when the entry's data can't be read.
      def stream_out(zip_entry, name, path)
        return over_byte_limit(name) if zip_entry.size.to_i > @max_uncompressed_bytes - @bytes_read

        digest = Digest::SHA256.new
        byte_size = 0
        File.open(path, "wb") do |out|
          zip_entry.get_input_stream do |input|
            while (chunk = input.sysread(CHUNK_SIZE)) && !chunk.empty?
              byte_size += chunk.bytesize
              @bytes_read += chunk.bytesize
              raise LimitReached if @bytes_read > @max_uncompressed_bytes

              digest << chunk
              out.write(chunk)
            end
          end
        end
        [ byte_size, digest.hexdigest ]
      rescue LimitReached
        over_byte_limit(name)
      rescue StandardError => error # nothing here yields either
        report_unexpected(error)
        rejected(name, "Couldn't read this file from the zip (#{error_text(error)})")
      end

      def over_byte_limit(name)
        limit = "#{ActiveSupport::NumberHelper.number_to_human_size(@max_uncompressed_bytes)} uncompressed"
        @limit_message = "Stopped at the #{limit} limit for one batch (zip-bomb guard): " \
                         "#{name} and anything after it were not imported."
        rejected(name, "Over the #{limit} limit for one batch: not imported")
      end

      def file_entry(path, name, content_type, from_zip:, byte_size: File.size(path), sha256: nil)
        sha256 ||= Digest::SHA256.file(path).hexdigest
        unless Config.supported?(content_type)
          return rejected(name, "Unsupported file type (#{content_type}): only PDF, JPG, PNG, HEIC and WEBP are read",
            sha256: sha256, from_zip: from_zip)
        end

        Entry.new(name: name, path: path.to_s, content_type: content_type, byte_size: byte_size, sha256: sha256,
          from_zip: from_zip, rejection_reason: nil)
      end

      def rejected(name, reason, sha256: nil, from_zip: true)
        Entry.new(name: name, path: nil, content_type: nil, byte_size: nil, sha256: sha256, from_zip: from_zip,
          rejection_reason: reason)
      end

      def skip(name)
        @skipped << name
        nil
      end

      def next_path
        @sequence += 1
        @dir.join(format("entry-%06d", @sequence)).to_s
      end

      # Entry names are raw bytes: UTF-8 when valid as such (zips flag it, or it's plain
      # ASCII), otherwise the zip format's default code page 437.
      def decode(raw)
        utf8 = raw.dup.force_encoding(Encoding::UTF_8)
        return utf8 if utf8.valid_encoding?

        raw.dup.force_encoding(Encoding::IBM437).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end

      # Printable, and short enough to store; a long name keeps its end (the file name).
      def clean_name(name)
        name = name.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?").gsub(/[[:cntrl:]]/, "?")
        name.length > MAX_NAME_LENGTH ? "…#{name.last(MAX_NAME_LENGTH - 1)}" : name
      end

      def unsafe_path?(name)
        name.include?("\0") || name.start_with?("/", "\\") || name.match?(/\A[A-Za-z]:/) ||
          name.split(%r{[/\\]}).include?("..")
      end

      def junk?(name)
        segments = name.split(%r{[/\\]}).compact_blank
        return true if segments.empty?

        segments.any? { |segment| JUNK_FOLDERS.include?(segment.downcase) || hidden?(segment) } ||
          JUNK_FILENAMES.include?(segments.last.downcase)
      end

      def hidden?(segment)
        segment.start_with?(".") && segment != "."
      end

      def error_text(error)
        "#{error.class.name.demodulize}: #{error.message.truncate(120)}"
      end

      # A zip that can't be read is expected (READ_ERRORS); anything else rubyzip raised is
      # reported. No names: they can be people's.
      def report_unexpected(error)
        return if READ_ERRORS.any? { |kind| error.is_a?(kind) }

        Rails.error.report(error, handled: true, source: "imports.archive")
      end

      def number(value)
        ActiveSupport::NumberHelper.number_to_delimited(value)
      end
  end
end
