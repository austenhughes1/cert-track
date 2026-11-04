require "test_helper"
require "support/import_samples"

class Imports::ArchiveTest < ActiveSupport::TestCase
  setup do
    @root = Pathname(Dir.mktmpdir("archive-test-"))
    @dir = @root.join("work").tap(&:mkpath)
    @pdf = ImportSamples.pdf({})
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  test "a plain upload is one entry, typed and hashed from its bytes" do
    entries, archive = expand(@pdf, "ortiz card.pdf")

    assert_equal 1, entries.size
    entry = entries.first
    assert entry.accepted?
    assert_equal [ "ortiz card.pdf", "application/pdf", @pdf.bytesize, Digest::SHA256.hexdigest(@pdf), false ],
      [ entry.name, entry.content_type, entry.byte_size, entry.sha256, entry.from_zip ]
    assert_equal 1, archive.entries_seen
    assert_nil archive.limit_message
  end

  test "the type comes from the content, not the name" do
    jpeg = ImportSamples.image({}, format: :jpeg)
    assert_equal "image/jpeg", expand(jpeg, "card.pdf").first.first.content_type
    assert_equal "application/pdf", expand(@pdf, "card.jpg").first.first.content_type

    fake, = expand("just some text pretending to be a PDF", "card.pdf")
    assert fake.first.rejected?
    assert_match "Unsupported file type (application/octet-stream)", fake.first.rejection_reason
    assert_equal Digest::SHA256.hexdigest("just some text pretending to be a PDF"), fake.first.sha256
  end

  test "detects every supported image type" do
    formats = { png: "image/png", webp: "image/webp", jpeg: "image/jpeg" }
    formats[:heic] = "image/heic" if ImportSamples.heic_supported?
    formats.each do |format, type|
      entries, = expand(ImportSamples.image({}, format: format), "photo.bin")
      assert_equal type, entries.first.content_type, format
    end

    heic, = expand(file_fixture("certificate.heic").binread, "IMG_0001.HEIC")
    assert_equal "image/heic", heic.first.content_type
  end

  test "HEIC and HEIF brands Marcel misses, and AVIF is not HEIC" do
    box = ->(major, *compatible) { [ 16 + 4 * compatible.size ].pack("N") + "ftyp#{major}\0\0\0\0#{compatible.join}" + "\0" * 8 }

    assert_equal "image/heic", Imports::Archive.heif_type(box.call("heix", "mif1", "heic"))
    assert_equal "image/heic", Imports::Archive.heif_type(box.call("mif1", "heic"))
    assert_equal "image/heif", Imports::Archive.heif_type(box.call("msf1", "iso8"))
    assert_nil Imports::Archive.heif_type(box.call("mif1", "avif"))
    assert_nil Imports::Archive.heif_type(box.call("isom", "mp41"))
    assert_nil Imports::Archive.heif_type("%PDF-1.4")
  end

  test "a zip yields each file with its path inside the zip" do
    zip = ImportSamples.zip(
      "cards/" => nil,
      "cards/ortiz.pdf" => @pdf,
      "cards/chen.png" => ImportSamples.image({ holder: "Li Chen" }, format: :png),
      "garcia.webp" => ImportSamples.image({ holder: "Maria Garcia" }, format: :webp),
      "notes.txt" => "remember to renew"
    )
    entries, archive = expand(zip, "crew.zip")

    assert_equal [ "crew.zip/cards/ortiz.pdf", "crew.zip/cards/chen.png", "crew.zip/garcia.webp", "crew.zip/notes.txt" ],
      entries.map(&:name)
    assert_equal [ "application/pdf", "image/png", "image/webp", nil ], entries.map(&:content_type)
    assert entries.first(3).all?(&:accepted?)
    assert entries.first(3).all?(&:from_zip)
    assert_equal "ortiz.pdf", entries.first.filename
    assert_equal Digest::SHA256.hexdigest(@pdf), entries.first.sha256
    assert_match "Unsupported file type", entries.last.rejection_reason
    assert_equal 4, archive.entries_seen
  end

  test "entry files exist inside the block and are deleted after it" do
    zip = ImportSamples.zip("a.pdf" => @pdf, "b.pdf" => ImportSamples.pdf({ holder: "Li Chen" }))
    paths = []
    write(zip, "crew.zip").then do |path|
      Imports::Archive.new(@dir).expand(path, name: "crew.zip") do |entry|
        assert File.exist?(entry.path)
        assert_equal entry.byte_size, File.size(entry.path)
        assert_equal @dir.to_s, File.dirname(entry.path)
        paths << entry.path
      end
    end

    assert_equal 2, paths.uniq.size
    paths.each { |path| assert_not File.exist?(path) }
    assert_empty @dir.children
  end

  test "skips Mac, Windows and hidden junk without counting it" do
    zip = ImportSamples.zip(
      "__MACOSX/._ortiz.pdf" => "AppleDouble", "__MACOSX/cards/x.pdf" => @pdf, ".DS_Store" => "\0\0\0\1Bud1",
      "cards/.DS_Store" => "x", "cards/Thumbs.db" => "x", "Desktop.ini" => "x", "cards/.hidden.pdf" => @pdf,
      ".git/config" => "x", "cards/ortiz.pdf" => @pdf
    )
    entries, archive = expand(zip, "crew.zip")

    assert_equal [ "crew.zip/cards/ortiz.pdf" ], entries.map(&:name)
    assert_equal 1, archive.entries_seen
    assert_equal 8, archive.skipped.size
    assert_includes archive.skipped, "crew.zip/__MACOSX/._ortiz.pdf"

    top_level, = expand("\0\0\0\1Bud1", ".DS_Store")
    assert_empty top_level
  end

  test "zip-slip and absolute paths are rejected and nothing is written outside the work folder" do
    zip = ImportSamples.zip(
      "../evil.pdf" => @pdf, "cards/../../evil.pdf" => @pdf, "/tmp/evil.pdf" => @pdf, "C:/evil.pdf" => @pdf,
      "..\\other\\evil.pdf" => @pdf, "../.DS_Store" => "x", "cards/ok.pdf" => @pdf
    )
    system_tmp_evil = File.exist?("/tmp/evil.pdf")
    entries, archive = expand(zip, "crew.zip")

    rejected = entries.select(&:rejected?)
    assert_equal [ "crew.zip/../evil.pdf", "crew.zip/cards/../../evil.pdf", "crew.zip//tmp/evil.pdf", "crew.zip/C:/evil.pdf",
                   "crew.zip/../other/evil.pdf", "crew.zip/../.DS_Store" ], rejected.map(&:name)
    assert rejected.all? { |entry| entry.rejection_reason.include?("zip-slip") }
    assert rejected.all? { |entry| entry.path.nil? && entry.sha256.nil? }
    assert_equal [ "crew.zip/cards/ok.pdf" ], entries.select(&:accepted?).map(&:name)
    assert_equal 7, archive.entries_seen

    assert_equal [ "upload", "work" ], @root.children.map { |child| child.basename.to_s }.sort
    assert_empty Dir.glob(@root.join("**", "*evil*").to_s)
    assert_empty Dir.glob(@root.parent.join("*evil*").to_s)
    assert_equal system_tmp_evil, File.exist?("/tmp/evil.pdf")
  end

  test "nested zips two levels down are read; a third level is rejected" do
    two, archive = expand(ImportSamples.nested_zip(2, "card.pdf" => @pdf), "outer.zip")
    assert_equal [ "outer.zip/level1.zip/level2.zip/card.pdf" ], two.map(&:name)
    assert two.first.accepted?
    assert_equal 1, archive.entries_seen

    three, archive = expand(ImportSamples.nested_zip(3, "card.pdf" => @pdf), "outer.zip")
    assert_equal [ "outer.zip/level1.zip/level2.zip/level3.zip" ], three.map(&:name)
    assert_match "Zip nested more than 2 levels deep", three.first.rejection_reason
    assert_match(/\A\h{64}\z/, three.first.sha256)
    assert_equal 1, archive.entries_seen
  end

  test "max_zip_depth comes from the config" do
    Imports::Config.with(max_zip_depth: 0) do
      entries, = expand(ImportSamples.nested_zip(1, "card.pdf" => @pdf), "outer.zip")
      assert_equal [ "outer.zip/level1.zip" ], entries.map(&:name)
      assert entries.first.rejected?
    end
  end

  test "stops at max_entries and accounts for the cut-off file and later uploads" do
    zip = ImportSamples.zip((1..5).to_h { |n| [ "card#{n}.pdf", ImportSamples.pdf({ number: "N-#{n}" }) ] })
    archive = Imports::Archive.new(@dir, max_entries: 3)
    entries = []
    archive.expand(write(zip, "crew.zip"), name: "crew.zip") { |entry| entries << entry }

    assert_equal 3, entries.count(&:accepted?)
    assert_equal [ "crew.zip/card4.pdf" ], entries.select(&:rejected?).map(&:name)
    assert_match "Over the 3-file limit", entries.last.rejection_reason
    assert_match "Stopped at the 3-file limit for one batch: crew.zip/card4.pdf", archive.limit_message
    assert archive.limit_reached?

    later = []
    archive.expand(write(@pdf, "late.pdf"), name: "late.pdf") { |entry| later << entry }
    assert_equal [ "late.pdf" ], later.map(&:name)
    assert_match "Not imported", later.first.rejection_reason
    assert_equal 5, archive.entries_seen
  end

  test "a zip listing more records than the batch allows is rejected unopened, junk included" do
    junk = (1..20).to_h { |n| [ "__MACOSX/#{n}", "x" ] }
    zip = ImportSamples.zip(junk.merge("cards/" => nil, "cards/ortiz.pdf" => @pdf))
    entries, archive = expand(zip, "crew.zip", max_entries: 3) # 15 records: 3 x RECORDS_PER_ENTRY

    assert_equal [ "crew.zip" ], entries.map(&:name)
    assert_match "This zip lists 22 entries, over the 15-entry zip limit for one batch (zip-bomb guard)", entries.sole.rejection_reason
    assert_match "Stopped at the 15-entry zip limit for one batch (zip-bomb guard): crew.zip lists 22 entries", archive.limit_message
    assert_empty archive.skipped, "never opened, so nothing was walked"
    assert_equal [ 1, 0 ], [ archive.entries_seen, archive.zip_records ]

    later = []
    archive.expand(write(@pdf, "late.pdf"), name: "late.pdf") { |entry| later << entry }
    assert_match "Not imported", later.sole.rejection_reason
  end

  test "folders, junk and nested zips all draw on one record budget for the batch" do
    nested = (1..4).to_h { |n| [ "n#{n}.zip", ImportSamples.zip("__MACOSX/a" => "x", "__MACOSX/b" => "x") ] }
    zip = ImportSamples.zip({ "card.pdf" => @pdf }.merge(nested))
    entries, archive = expand(zip, "crew.zip", max_zip_records: 10)

    # crew.zip holds 5 records, n1 and n2 two each (9); n3's two don't fit, n4 is never reached.
    assert_equal [ "crew.zip/card.pdf", "crew.zip/n3.zip" ], entries.map(&:name)
    assert entries.first.accepted?
    assert_match "This zip lists 2 entries, over the 10-entry zip limit", entries.last.rejection_reason
    assert archive.limit_reached?
    assert_equal 9, archive.zip_records
    assert_equal 4, archive.skipped.size
    assert_equal 2, archive.entries_seen
  end

  test "a zip whose end record declares millions of entries is refused before its directory is read" do
    zip = declaring_entries(ImportSamples.zip("card.pdf" => @pdf), 5_000_000) # Zip64 end record
    assert_equal 5_000_000, Zip::File.count_entries(write(zip, "bomb.zip"))

    entries, archive = expand(zip, "bomb.zip")

    assert_match "This zip lists 5,000,000 entries, over the 10,000-entry zip limit", entries.sole.rejection_reason
    assert_match "zip-bomb guard", archive.limit_message
    assert_equal 0, archive.zip_records
  end

  # --- the central directory's size (zip-bomb guard) ---

  test "a zip whose list of files is far bigger than its entries need is rejected unopened; the batch goes on" do
    bloated = hand_zip([ [ "a.pdf", @pdf, { comment: "c" * 30_000 } ], [ "b.pdf", @pdf, { comment: "c" * 30_000 } ] ])
    entries, archive = expand(bloated, "crew.zip")

    assert_equal [ "crew.zip" ], entries.map(&:name)
    assert_equal "This zip's list of files is larger than 4 KB for its 2 entries (zip-bomb guard): not opened",
      entries.sole.rejection_reason
    assert_not archive.limit_reached?, "only this zip is refused"
    assert_equal [ 1, 0 ], [ archive.entries_seen, archive.zip_records ]

    later = []
    archive.expand(write(ImportSamples.zip("card.pdf" => @pdf), "next.zip"), name: "next.zip") { |entry| later << entry }
    assert later.sole.accepted?
  end

  test "records bigger than the declared directory size are measured, not trusted" do
    files = Array.new(3) { |n| [ "#{n}.pdf", @pdf, { extra: unknown_extra(20_000) } ] }
    lying = hand_zip(files, declared_size: 3 * 46) # rubyzip reads the records whatever size is declared
    assert_equal 3, Zip::File.open_buffer(StringIO.new(lying)).entries.size

    entries, = expand(lying, "crew.zip")

    assert_match "list of files is larger than 6 KB for its 3 entries", entries.sole.rejection_reason
  end

  test "many records sharing one local header with a big extra field are counted too" do
    files = Array.new(40) { |n| [ "card#{n}.pdf", @pdf, { local_offset: 0 } ] }
    shared = hand_zip(files, first_local_extra: unknown_extra(60_000)) # rubyzip would load that field 40 times

    entries, = expand(shared, "crew.zip")

    assert_match "list of files is larger than 80 KB for its 40 entries", entries.sole.rejection_reason
  end

  test "a Zip64 end record declaring an oversized directory is rejected" do
    zip = hand_zip([ [ "card.pdf", "%PDF-1.4\n" + ("x" * 10_000) ] ])
    entries, = expand(zip64_end(zip, records: 1, size: 9_000, offset: 0), "crew.zip")

    assert_match "list of files is larger than 2 KB for its 1 entry (zip-bomb guard)", entries.sole.rejection_reason
  end

  test "an honest Zip64 end record found through its locator, past a long comment, opens normally" do
    zip = ImportSamples.zip("cards/ortiz.pdf" => @pdf)
    at = zip.b.rindex("PK\x05\x06".b)
    records, size, offset = zip.b.byteslice(at, 22).unpack("VvvvvVVv").values_at(4, 5, 6)
    zip64 = zip64_end(zip, records:, size:, offset:, comment: "z" * 0xFFFF) # the Zip64 record is outside the tail read

    entries, = expand(zip64, "crew.zip")

    assert_equal [ "crew.zip/cards/ortiz.pdf" ], entries.map(&:name)
    assert entries.sole.accepted?
  end

  test "a Zip64 end record far before its locator is refused before rubyzip reads up to it" do
    zip = ImportSamples.zip("card.pdf" => @pdf)
    records, size, offset = end_record(zip)
    far = zip64_end(zip, records:, size:, offset:, gap: "\0" * 70_000) # rubyzip would read all of it into one String, twice

    entries, archive = expand(far, "crew.zip") # Directory refuses it before rubyzip's count_entries runs

    assert_equal "Couldn't open this zip (Error: the Zip64 end of central directory record is not next to its locator)",
      entries.sole.rejection_reason
    assert_not archive.limit_reached?, "only this zip is refused"
  end

  test "a Zip64 end record with extensible data, found through its locator, opens normally" do
    zip = ImportSamples.zip("cards/ortiz.pdf" => @pdf)
    records, size, offset = end_record(zip)
    zip64 = zip64_end(zip, records:, size:, offset:, extensible: "x" * 60_000, comment: "z" * 0xFFFF)

    entries, = expand(zip64, "crew.zip")

    assert_equal [ "crew.zip/cards/ortiz.pdf" ], entries.map(&:name)
    assert entries.sole.accepted?
  end

  test "long UTF-8 names and the usual extra fields are well within the allowance" do
    files = (1..30).to_h { |n| [ "Zertifikate 2026/Mitarbeiterinnen und Mitarbeiter/#{"証明書" * 40} #{n}.pdf", @pdf ] }
    entries, = expand(ImportSamples.zip(files), "crew.zip")

    assert_equal 30, entries.count(&:accepted?)
  end

  test "a directory said to run past the end of the file, or a cut-short end record, is an unreadable zip" do
    past_end = hand_zip([ [ "a.pdf", @pdf ] ], declared_size: 0xFFFF_FFF0)
    cut_short = "PK\x03\x04 not much of a zip".b + [ 0x06054b50 ].pack("V") + "\0\0" # rubyzip's own reader crashes here

    [ past_end, cut_short ].each do |bytes|
      entries, archive = expand(bytes, "crew.zip")
      assert_match "Couldn't open this zip", entries.sole.rejection_reason
      assert_equal 1, archive.entries_seen
    end
  end

  test "a nested zip gets the same directory check" do
    bloated = hand_zip([ [ "a.pdf", @pdf, { comment: "c" * 30_000 } ] ])
    entries, = expand(ImportSamples.zip("card.pdf" => @pdf, "inner/bloated.zip" => bloated), "crew.zip")

    assert_equal [ "crew.zip/card.pdf", "crew.zip/inner/bloated.zip" ], entries.map(&:name)
    assert entries.first.accepted?
    assert_match "list of files is larger than 2 KB for its 1 entry", entries.last.rejection_reason
  end

  test "stops past max_uncompressed_bytes, counted across entries" do
    zip = ImportSamples.zip("a.pdf" => "%PDF-1.4\n" + "a" * 600, "b.pdf" => "%PDF-1.4\n" + "b" * 600, "c.pdf" => @pdf)
    archive = Imports::Archive.new(@dir, max_uncompressed_bytes: 1_000)
    entries = []
    archive.expand(write(zip, "crew.zip"), name: "crew.zip") { |entry| entries << entry }

    assert_equal [ "crew.zip/a.pdf", "crew.zip/b.pdf" ], entries.map(&:name)
    assert entries.first.accepted?
    assert_match "Over the 1000 Bytes uncompressed limit", entries.last.rejection_reason
    assert_match "zip-bomb guard", archive.limit_message
    assert_empty @dir.children
  end

  test "counts the bytes actually inflated, not the size the header declares" do
    bomb = ImportSamples.declare_size(ImportSamples.zip("bomb.pdf" => "%PDF-1.4\n" + "\0" * 500_000), "bomb.pdf", 100)
    assert_equal [ 100 ], Zip::File.open_buffer(StringIO.new(bomb)).entries.map(&:size)

    archive = Imports::Archive.new(@dir, max_uncompressed_bytes: 10_000)
    entries = []
    archive.expand(write(bomb, "bomb.zip"), name: "bomb.zip") { |entry| entries << entry }

    assert_equal 1, entries.size
    assert entries.first.rejected?
    assert_match "uncompressed limit", entries.first.rejection_reason
    assert_operator archive.bytes_read, :>, 10_000
    assert_operator archive.bytes_read, :<=, 10_000 + Imports::Archive::CHUNK_SIZE # stopped at the first chunk past it
    assert_empty @dir.children
  end

  test "a declared size over the limit is refused without reading" do
    zip = ImportSamples.declare_size(ImportSamples.zip("a.pdf" => @pdf), "a.pdf", 5_000_000)
    archive = Imports::Archive.new(@dir, max_uncompressed_bytes: 1_000_000)
    entries = []
    archive.expand(write(zip, "crew.zip"), name: "crew.zip") { |entry| entries << entry }

    assert entries.first.rejected?
    assert_equal 0, archive.bytes_read
  end

  test "a corrupt zip is one rejected entry" do
    entries, archive = nil
    assert_no_error_reported { entries, archive = expand("PK\x03\x04 this is not really a zip", "crew.zip") }

    assert_equal [ "crew.zip" ], entries.map(&:name)
    assert_match "Couldn't open this zip", entries.first.rejection_reason
    assert_equal 1, archive.entries_seen
  end

  test "a zip rubyzip trips over with a plain Ruby error is one rejected entry, reported, and the batch goes on" do
    cut_short = hand_zip([ [ "a.pdf", @pdf, { extra: "UT" } ] ]) # a known ID (universal time) with no length after it
    archive = Imports::Archive.new(@dir)
    entries = []

    assert_error_reported(NoMethodError) do
      archive.expand(write(cut_short, "crew.zip"), name: "crew.zip") { |entry| entries << entry }
    end
    archive.expand(write(ImportSamples.zip("card.pdf" => @pdf), "more.zip"), name: "more.zip") { |entry| entries << entry }

    assert_equal [ "crew.zip", "more.zip/card.pdf" ], entries.map(&:name)
    assert_match "Couldn't open this zip (NoMethodError: ", entries.first.rejection_reason
    assert entries.last.accepted?
    assert_equal 2, archive.entries_seen
  end

  test "an entry rubyzip trips over while reading it is rejected on its own, reported, and the zip's other files are read" do
    # An empty Zip64 field in the record makes rubyzip skip the local header when it opens the zip;
    # reading the entry then meets the local header's universal-time field, cut short after its ID.
    zip = hand_zip([ [ "a.pdf", @pdf, { extra: [ 0x0001, 0 ].pack("vv") } ], [ "b.pdf", @pdf ] ], first_local_extra: "UT")
    entries = nil
    assert_error_reported(NoMethodError) { entries, = expand(zip, "crew.zip") }

    assert_equal [ "crew.zip/a.pdf", "crew.zip/b.pdf" ], entries.map(&:name)
    assert_match "Couldn't read this file from the zip (NoMethodError: ", entries.first.rejection_reason
    assert entries.last.accepted?
    assert_empty @dir.children
  end

  test "errors raised by the block propagate, from a zip too" do
    zip = ImportSamples.zip("a.pdf" => @pdf, "inner.zip" => ImportSamples.zip("b.pdf" => @pdf))
    [ [ "card.pdf", @pdf, 1 ], [ "crew.zip", zip, 1 ], [ "crew.zip", zip, 2 ] ].each do |name, bytes, fail_at|
      archive = Imports::Archive.new(@dir)
      seen = 0
      error = assert_raises(NoMethodError, name) do
        archive.expand(write(bytes, name), name: name) { (seen += 1) == fail_at ? nil.upcase : nil }
      end
      assert_match "upcase", error.message
      assert_equal fail_at, seen
    end
  end

  test "a password-protected entry is rejected" do
    buffer = Zip::OutputStream.write_buffer(StringIO.new(+""), encrypter: Zip::TraditionalEncrypter.new("secret")) do |zip|
      zip.put_next_entry("locked.pdf")
      zip.write(@pdf)
    end
    entries, = expand(buffer.string, "locked.zip")

    assert_equal [ "locked.zip/locked.pdf" ], entries.map(&:name)
    assert_match "Password-protected", entries.first.rejection_reason
  end

  test "entry names that aren't UTF-8 are read as code page 437, and long names are shortened" do
    long = "#{"folder/" * 60}ortiz.pdf"
    zip = ImportSamples.zip("r\x82sum\x82.pdf".b => @pdf, long => @pdf)
    entries, = expand(zip, "crew.zip")

    assert_equal "crew.zip/résumé.pdf", entries.first.name
    assert_equal Encoding::UTF_8, entries.first.name.encoding
    assert_equal 255, entries.last.name.length
    assert entries.last.name.end_with?("folder/ortiz.pdf")
  end

  private
    # Expands bytes saved as name; returns [entries, archive].
    def expand(bytes, name, **limits)
      archive = Imports::Archive.new(@dir, **limits)
      entries = []
      archive.expand(write(bytes, name), name: name) { |entry| entries << entry }
      [ entries, archive ]
    end

    def write(bytes, name)
      ImportSamples.write(@root.join("upload"), SecureRandom.hex(4) + File.extname(name.to_s), bytes).to_s
    end

    # A zip built by hand, entries stored: files are [name, data, options] with options
    #   comment:      the entry's file comment (central directory)
    #   extra:        its central-directory extra field
    #   local_offset: the local header offset its record points to (default: its own)
    # first_local_extra: an extra field in the first entry's local header. declared_size: the
    # central-directory size the end record states (default: the real one).
    def hand_zip(files, first_local_extra: "", declared_size: nil)
      body = "".b
      directory = "".b
      date = ((2026 - 1980) << 9) | (11 << 5) | 3 # Nov 3, 2026 in MS-DOS format; time 00:00
      files.each_with_index do |(name, data, options), index|
        options ||= {}
        offset = body.bytesize
        crc = Zlib.crc32(data)
        local_extra = index.zero? ? first_local_extra.b : "".b
        body << [ 0x04034b50, 20, 0, 0, 0, date, crc, data.bytesize, data.bytesize, name.bytesize, local_extra.bytesize ].pack("VvvvvvVVVvv")
        body << name.b << local_extra << data.b
        extra = options.fetch(:extra, "").b
        comment = options.fetch(:comment, "").b
        directory << [ 0x02014b50, 20, 20, 0, 0, 0, date, crc, data.bytesize, data.bytesize, name.bytesize, extra.bytesize,
          comment.bytesize, 0, 0, 0, options.fetch(:local_offset, offset) ].pack("VvvvvvvVVVvvvvvVV")
        directory << name.b << extra << comment
      end
      body + directory + [ 0x06054b50, 0, 0, files.size, files.size, declared_size || directory.bytesize, body.bytesize, 0 ].pack("VvvvvVVv")
    end

    # An extra field of an ID nothing knows, so rubyzip keeps it as is, length bytes long in all.
    def unknown_extra(length)
      [ 0xCAFE, length - 4 ].pack("vv") + ("e" * (length - 4))
    end

    # zip_bytes with its end record replaced by a Zip64 end record stating records, size and
    # offset (followed by extensible data, counted in its size), then gap, its locator, and a
    # plain end record whose fields are maxed out (plus comment).
    def zip64_end(zip_bytes, records:, size:, offset:, comment: "", extensible: "", gap: "")
      bytes = zip_bytes.b
      body = bytes.byteslice(0, bytes.rindex("PK\x05\x06".b))
      zip64 = [ 0x06064b50, 44 + extensible.bytesize, 45, 45, 0, 0, records, records, size, offset ].pack("VQ<vvVVQ<Q<Q<Q<") + extensible.b
      locator = [ 0x07064b50, 0, body.bytesize, 1 ].pack("VVQ<V")
      body + zip64 + gap.b + locator +
        [ 0x06054b50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, comment.bytesize ].pack("VvvvvVVv") + comment.b
    end

    # zip_bytes's end-record fields: [records, directory size, directory offset].
    def end_record(zip_bytes)
      bytes = zip_bytes.b
      bytes.byteslice(bytes.rindex("PK\x05\x06".b), 22).unpack("VvvvvVVv").values_at(4, 5, 6)
    end

    # zip_bytes with its end record replaced by a Zip64 one declaring count entries (and a
    # central directory big enough to hold them, so rubyzip has nothing to warn about).
    def declaring_entries(zip_bytes, count)
      bytes = zip_bytes.b
      at = bytes.rindex("PK\x05\x06".b)
      _, _, _, _, _, size, offset, = bytes.byteslice(at, 22).unpack("VvvvvVVv")
      body = bytes.byteslice(0, at)
      zip64 = [ 0x06064b50, 44, 45, 45, 0, 0, count, count, [ size, count * 46 ].max, offset ].pack("VQ<vvVVQ<Q<Q<Q<")
      locator = [ 0x07064b50, 0, body.bytesize, 1 ].pack("VVQ<V")
      body + zip64 + locator + [ 0x06054b50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0 ].pack("VvvvvVVv")
    end
end
