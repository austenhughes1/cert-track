require "combine_pdf"
require "vips"

module Certificates
  # Makes a scanned PDF smaller without touching anything but its big page images: each
  # embedded JPEG drawn at more than MAX_PPI is re-encoded in place at TARGET_PPI, quality 80.
  # Page content, the text layer of a searchable scan, fonts, links, outlines and document
  # metadata are copied through as they are (combine_pdf). A PDF made on a computer has no
  # big images, so it is left alone.
  #
  #   Certificates::PdfShrinker.new(source_path, output_path, under: 800_000).call
  #   # => output_path, or nil when the PDF is left as it is
  #
  # Anything unusual is left alone too: an encrypted, signed, form, layered or attachment-
  # carrying PDF, and every image that isn't a plain 8-bit gray or RGB JPEG (CMYK, DeviceN,
  # Indexed, Lab, Flate, JBIG2, CCITT, JPX, masks, Decode arrays, inline images). The new
  # file is kept only when it is smaller than `under` bytes and poppler agrees it is the same
  # document: the same page count and text, and every page renders and looks the same at
  # thumbnail size.
  class PdfShrinker
    MAX_PPI = 220
    TARGET_PPI = 200
    QUALITY = 80
    TOOL_TIMEOUT = 120 # seconds per poppler call; the renders cover every page
    RENDER_SIDE = 200 # px, the long side of the page renders compared before and after
    MAX_RENDER_DIFFERENCE = 1.5 # mean gray-level change (0-255) allowed; a good re-encode shows about 0.5

    # Catalog entries combine_pdf rebuilds itself, and those Document carries over unchanged.
    # A PDF whose catalog holds anything else (AcroForm: forms and signatures; Names: attached
    # files and scripts; OCProperties: layers; Perms; actions) is left alone.
    REBUILT_CATALOG_KEYS = %i[Type Pages Outlines].freeze
    CARRIED_CATALOG_KEYS = %i[Version Extensions Lang Metadata MarkInfo StructTreeRoot PageLabels PageLayout PageMode
      ViewerPreferences OutputIntents OpenAction].freeze
    # Image dictionary entries a re-encoded JPEG keeps as they are; any other entry (SMask,
    # Mask, Decode, DecodeParms, ImageMask, Alternates, OC, ...) leaves that image alone.
    IMAGE_KEYS = %i[Type Subtype Width Height ColorSpace BitsPerComponent Filter Length Interpolate Intent Name Metadata
      StructParent ID].freeze
    # One row of `pdfimages -list` (after its two header lines): page, num, type, width,
    # height, color, comp, bpc, enc, interp, object id (or [inline]/[none]), x-ppi, y-ppi, ...
    LIST_ROW = /\A\s*\d+\s+\d+\s+(?<type>\S+)\s+\d+\s+\d+\s+(?<color>\S+)\s+(?<comp>\d+)\s+(?<bpc>\d+)\s+(?<enc>\S+)\s+\S+\s+
      (?:(?<num>\d+)\s+(?<gen>\d+)|\[\w+\])\s+(?<xppi>\d+)\s+(?<yppi>\d+)\s/x

    # combine_pdf rebuilds the document catalog with only its pages, outlines and names; this
    # keeps the rest of it (XMP metadata, tags, language, page labels, viewer settings).
    class Document < CombinePDF::PDF
      def initialize(parser, catalog_entries)
        @catalog_entries = catalog_entries
        super(parser)
      end

      protected
        def rebuild_catalog(*)
          super.merge!(@catalog_entries)
        end
    end

    attr_reader :source, :output, :under

    def initialize(source, output, under:)
      @source = source.to_s
      @output = output.to_s
      @under = under
    end

    def call
      ppi = big_jpegs
      return if ppi.blank?

      data = shrunk_pdf(ppi)
      return if data.nil? || data.bytesize >= under

      File.binwrite(output, data)
      output if same_document?
    rescue Imports::Shell::CommandNotFound
      raise # poppler is missing: a server problem, not this file's
    rescue CombinePDF::ParsingError, CombinePDF::EncryptionError, Imports::Shell::Error, Vips::Error,
      SystemStackError => error # combine_pdf parses recursively, so a deeply nested PDF overflows the stack
      leave_alone("#{error.class}: #{error.message.to_s.truncate(200)}")
    rescue StandardError => error # combine_pdf on a PDF it doesn't understand; the original is still there
      Rails.error.report(error, handled: true, source: "certificates.pdf_shrinker")
      leave_alone("#{error.class}: #{error.message.to_s.truncate(200)}")
    end

    private
      # { [object number, generation] => effective ppi } for every JPEG image drawn above MAX_PPI
      # everywhere it appears (its lowest x or y resolution on any page); nil for a listing
      # this can't read.
      def big_jpegs
        lines = Imports::Shell.run("pdfimages", "-list", source, timeout: TOOL_TIMEOUT).lines.drop(2).select { |line| line.strip.present? }
        rows = lines.filter_map { |line| LIST_ROW.match(line) }
        return leave_alone("pdfimages listed an image this can't read") if rows.size < lines.size

        rows.select { |row| row[:num] }.group_by { |row| [ row[:num].to_i, row[:gen].to_i ] }.filter_map do |ref, uses|
          next unless uses.all? { |use| plain_jpeg?(use) }

          ppi = uses.flat_map { |use| [ use[:xppi].to_i, use[:yppi].to_i ] }.min
          [ ref, ppi ] if ppi > MAX_PPI
        end.to_h
      end

      def plain_jpeg?(use)
        use[:type] == "image" && use[:enc] == "jpeg" && use[:bpc] == "8" &&
          %w[gray rgb icc].include?(use[:color]) && %w[1 3].include?(use[:comp])
      end

      # The whole PDF with those images re-encoded, or nil when there is nothing safe to change.
      def shrunk_pdf(ppi)
        parser = CombinePDF::PDFParser.new(File.binread(source), raise_on_encrypted: true)
        objects = parser.parse
        catalog = resolve(parser.root_object[:Root])
        return leave_alone("its catalog has entries that can't be copied safely") unless copyable_catalog?(catalog)
        return leave_alone("it is signed") if objects.any? { |object| object.is_a?(Hash) && object.key?(:ByteRange) }

        # Object numbers go once the document is built (CombinePDF::PDF.new), so match first.
        by_ref = objects.select { |object| object.is_a?(Hash) }.index_by { |object| [ object[:indirect_reference_id], object[:indirect_generation_number] || 0 ] }
        changed = ppi.count { |ref, image_ppi| (image = by_ref[ref]) && reencode(image, image_ppi) }
        return if changed.zero?

        info = parser.info_object.is_a?(Hash) ? parser.info_object.dup : nil # combine_pdf rewrites Producer and the dates
        document = Document.new(parser, catalog.slice(*CARRIED_CATALOG_KEYS))
        document.info.replace(info) if info
        document.to_pdf
      end

      def copyable_catalog?(catalog)
        return false unless catalog.is_a?(Hash)

        keys = catalog.keys - CombinePDF::PDF::PRIVATE_HASH_KEYS
        (keys - REBUILT_CATALOG_KEYS - CARRIED_CATALOG_KEYS).empty? &&
          (catalog[:OpenAction].nil? || catalog[:OpenAction].is_a?(Array)) # a page to open at, not a script
      end

      # Replaces image's JPEG with one at TARGET_PPI. False (image untouched) when it isn't a
      # plain gray or RGB JPEG after all, or the new one isn't smaller.
      def reencode(image, ppi)
        return false unless reencodable?(image)

        jpeg = Vips::Image.new_from_buffer(image[:raw_stream_content], "") # no autorotate: the PDF places it
        return false unless jpeg.get("vips-loader") == "jpegload_buffer" &&
          [ jpeg.width, jpeg.height, jpeg.bands ] == [ image[:Width], image[:Height], components(image[:ColorSpace]) ]

        smaller = jpeg.resize(TARGET_PPI.to_f / ppi)
        bytes = smaller.jpegsave_buffer(Q: QUALITY, optimize_coding: true, strip: true)
        return false if bytes.bytesize >= image[:raw_stream_content].bytesize

        image.merge!(raw_stream_content: bytes, Width: smaller.width, Height: smaller.height, Length: bytes.bytesize)
        true
      end

      def reencodable?(image)
        image[:Subtype] == :Image && Array(image[:Filter]) == [ :DCTDecode ] && image[:BitsPerComponent] == 8 &&
          image[:raw_stream_content].is_a?(String) && (image.keys - CombinePDF::PDF::PRIVATE_HASH_KEYS - IMAGE_KEYS).empty? &&
          components(image[:ColorSpace]).present?
      end

      # 1 or 3 for DeviceGray, DeviceRGB or a matching ICC profile (kept as it is: the pixels
      # stay in the same colour space); nil for anything else.
      def components(color_space)
        color_space = resolve(color_space)
        case color_space
        when :DeviceGray then 1
        when :DeviceRGB then 3
        when Array
          profile = resolve(color_space[1]) if color_space.size == 2 && color_space[0] == :ICCBased
          profile[:N] if profile.is_a?(Hash) && [ 1, 3 ].include?(profile[:N])
        end
      end

      def resolve(object)
        object.is_a?(Hash) && object[:is_reference_only] ? object[:referenced_object] : object
      end

      def same_document?
        pages = page_count(source)
        return leave_alone("the new PDF has a different page count") unless page_count(output) == pages
        return leave_alone("the new PDF's text differs") unless text(output) == text(source)
        return leave_alone("the new PDF's pages look different") unless same_renders?(pages)

        true
      end

      def page_count(path)
        Imports::Shell.run("pdfinfo", path, timeout: TOOL_TIMEOUT)[/^Pages:\s+(\d+)/, 1].to_i
      end

      def text(path)
        Imports::Shell.run("pdftotext", "-enc", "UTF-8", path, "-", timeout: TOOL_TIMEOUT)
      end

      # Renders every page of both files small and in gray, and compares them pixel by pixel.
      def same_renders?(pages)
        Dir.mktmpdir("certtrack-pdf-check-") do |dir|
          before, after = [ source, output ].each_with_index.map do |path, index|
            prefix = File.join(dir, index.to_s)
            Imports::Shell.run("pdftoppm", "-gray", "-png", "-scale-to", RENDER_SIDE, path, prefix, timeout: TOOL_TIMEOUT)
            Dir.glob("#{prefix}-*.png").sort
          end
          before.size == pages && after.size == pages &&
            before.zip(after).all? { |old, new| similar?(Vips::Image.new_from_file(old), Vips::Image.new_from_file(new)) }
        end
      end

      def similar?(old, new)
        [ old.width, old.height ] == [ new.width, new.height ] && (old.cast(:float) - new).abs.avg <= MAX_RENDER_DIFFERENCE
      end

      def leave_alone(reason)
        Rails.logger.info("[Certificates::PdfShrinker] #{File.basename(source)} left as it is: #{reason}")
        FileUtils.rm_f(output)
        nil
      end
  end
end
