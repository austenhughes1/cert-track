require "vips"

module Imports
  # Step 3 of the import pipeline: free, local text extraction. Nothing leaves the machine.
  #
  # PDFs are read one page at a time with `pdftotext -layout`. A page whose text layer is
  # missing or not usable (fewer than Imports::Config.ocr_min_chars letters and digits, or
  # mostly symbols) is a scan: it is rasterized with `pdftoppm -r 300` and read by tesseract.
  # Images (JPEG, PNG, WebP, HEIC/HEIF) are turned upright from their EXIF orientation and
  # converted to grayscale with libvips, then read by tesseract.
  #
  # When tesseract is unsure of a reading (an upside-down scan reads as nonsense), the page
  # is turned 180 degrees and read again, and the more confident reading wins. A reading it
  # is still very unsure of is noise, so it is dropped: the page text is empty, usable? is
  # false, and step 4 sends the page image to the vision model instead.
  #
  #   result = Imports::TextExtractor.new(path, content_type: "application/pdf").call
  #   result.text  # => "=== page 1 ===\nCERTIFICATE OF COMPLETION\n...\n\n=== page 2 ===\n..."
  #   result.pages # => [Page(number: 1, text: "CERTIFICATE ...", ocr: false), Page(number: 2, ..., ocr: true)]
  #
  # Raises TextExtractor::Error (unreadable, unsupported or oversized files) or an
  # Imports::Shell::Error (a tool is missing, failed or timed out).
  class TextExtractor
    class Error < StandardError; end
    class UnsupportedType < Error; end

    # number is 1-indexed; ocr is true when the text came from tesseract (the page is a scan
    # or a photo), false for a PDF text layer, nil when parsed back from stored text.
    Page = Data.define(:number, :text, :ocr)
    Result = Data.define(:text, :pages)
    # page_sizes: [[width, height], ...] in points for the first MAX_PAGES pages.
    PdfInfo = Data.define(:page_count, :page_sizes)

    PDF_TYPE = "application/pdf".freeze
    IMAGE_TYPES = %w[image/jpeg image/png image/webp image/heic image/heif].freeze
    CONTENT_TYPE_ALIASES = { "image/jpg" => "image/jpeg", "image/pjpeg" => "image/jpeg", "image/x-png" => "image/png" }.freeze
    # libvips loaders allowed to open an import image; anything else (SVG, PDF, Matlab...) is refused.
    IMAGE_LOADERS = %w[jpegload pngload webpload heifload].freeze

    LANGUAGES = "eng".freeze
    OCR_DPI = 300
    MAX_PAGES = 200
    MAX_RENDER_SIDE = 6_000 # px: an oversized PDF page is rendered at a lower dpi to bound memory
    MAX_OCR_SIDE = 5_000 # px: bigger photos are scaled down before OCR
    MAX_IMAGE_PIXELS = 200_000_000 # decompression-bomb guard, checked from the header
    # Tesseract's mean word confidence (0-100): clean text reads at about 95, an upside-down
    # or mirrored page at about 30-40.
    RETRY_CONFIDENCE = 70 # under this the page is also read upside down
    NOISE_CONFIDENCE = 50 # under this the reading is dropped as noise (the vision model reads the page)
    PAGE_MARKER = /^=== page (\d+) ===$/

    class << self
      # True when text (one page) has at least Imports::Config.ocr_min_chars letters and
      # digits, is mostly letters and digits (not OCR noise or a broken font encoding), and
      # has a few real words.
      def usable?(text)
        return false if text.blank?

        meaningful = meaningful_length(text)
        return false if meaningful < Imports::Config.ocr_min_chars

        visible = text.gsub(/([^\p{L}\p{N}\s])\1{2,}/, "").gsub(/\s+/, "") # signature lines (____) don't count
        words = text.scan(/\p{L}{3,}/).size
        meaningful >= visible.length * 0.5 && words >= 3
      end

      # Letters and digits in text.
      def meaningful_length(text)
        text.to_s.scan(/[\p{L}\p{N}]/).size
      end

      # The stored extracted_text: "=== page N ===\n<text>" blocks separated by a blank line.
      def join_pages(pages)
        pages.map { |page| "=== page #{page.number} ===\n#{page.text}" }.join("\n\n")
      end

      # Parses join_pages output back into Pages (ocr: nil). Text without markers is page 1.
      def split_pages(text)
        return [] if text.blank?
        return [ Page.new(number: 1, text: text.strip, ocr: nil) ] unless text.match?(PAGE_MARKER)

        text.split(/^=== page (\d+) ===\n?/).drop(1).each_slice(2).map do |number, body|
          Page.new(number: number.to_i, text: body.to_s.strip, ocr: nil)
        end
      end

      # "image/jpg; charset=binary" => "image/jpeg".
      def normalize_content_type(content_type)
        type = content_type.to_s.split(";").first.to_s.strip.downcase
        CONTENT_TYPE_ALIASES.fetch(type, type)
      end

      def supported?(content_type)
        type = normalize_content_type(content_type)
        type == PDF_TYPE || IMAGE_TYPES.include?(type)
      end

      # The declared content type when supported, else what the file's bytes say (a zip
      # entry or a mislabelled upload). Raises UnsupportedType for anything else.
      def detect_content_type(path, declared)
        type = normalize_content_type(declared)
        return type if supported?(type)

        sniffed = normalize_content_type(Marcel::MimeType.for(Pathname.new(path.to_s)))
        return sniffed if supported?(sniffed)

        raise UnsupportedType, "#{type.presence || sniffed} is not a supported file type (PDF, JPEG, PNG, WebP or HEIC)"
      end

      # The PDF's page count and page sizes, from pdfinfo. Raises Error for a file that
      # isn't a readable PDF (corrupt, password-protected).
      def pdf_info(path, timeout: Shell::DEFAULT_TIMEOUT)
        output = Shell.run("pdfinfo", "-f", 1, "-l", MAX_PAGES, File.expand_path(path.to_s), timeout: timeout)
        output = output.dup.force_encoding(Encoding::UTF_8).scrub("")
        sizes = output.scan(/^Page\s+\d+\s+size:\s+([\d.]+)\s+x\s+([\d.]+)/).map { |pair| pair.map(&:to_f) }
        PdfInfo.new(page_count: output[/^Pages:\s+(\d+)/, 1].to_i, page_sizes: sizes)
      rescue Shell::Failed => error
        raise Error, pdf_error_message(error)
      end

      def page_count(path, timeout: Shell::DEFAULT_TIMEOUT)
        pdf_info(path, timeout: timeout).page_count
      end

      # Highest dpi up to preferred at which a page whose long side is long_side_points
      # stays within MAX_RENDER_SIDE pixels.
      def render_dpi(long_side_points, preferred: OCR_DPI)
        return preferred unless long_side_points.to_f.positive?

        [ preferred, (MAX_RENDER_SIDE * 72.0 / long_side_points).floor ].min.clamp(1, preferred)
      end

      # Opens an import image upright (EXIF orientation applied), no larger than max_side on
      # either side, alpha flattened onto white. Refuses non-image loaders and pixel bombs.
      def load_image(path, max_side:)
        header = Vips::Image.new_from_file(path.to_s)
        loader = header.get("vips-loader").to_s
        raise UnsupportedType, "#{loader.presence || 'this'} is not a supported image format" unless IMAGE_LOADERS.any? { |name| loader.start_with?(name) }
        if header.width.to_i * header.height.to_i > MAX_IMAGE_PIXELS
          raise Error, "The image is too large to read (#{header.width} x #{header.height} pixels)"
        end

        image = Vips::Image.thumbnail(path.to_s, max_side, height: max_side, size: :down) # also applies EXIF orientation
        image.has_alpha? ? image.flatten(background: 255) : image
      rescue Vips::Error => error
        raise Error, "The image could not be read: #{vips_error_detail(error)}"
      end

      # The newest line of a libvips error (its error buffer is process-wide, so older lines
      # can belong to other files), without server file paths.
      def vips_error_detail(error)
        redact_paths(error.message.to_s.lines.map(&:strip).reject(&:empty?).last.to_s).truncate(200)
      end

      # Tool and library messages name temp files ("/tmp/ActiveStorage-12-abc.pdf"); users
      # only need to know it was their file.
      def redact_paths(text)
        text.gsub(%r{(["']?)(?<![\w.])/(?:[^/"'\s]+/)+[^"'\s]*\1}, "the file")
      end

      private
        def pdf_error_message(error)
          if error.stderr.match?(/password/i)
            "The PDF is password-protected. Remove the password and upload it again."
          else
            "The file could not be read as a PDF: #{redact_paths(error.stderr).truncate(200)}"
          end
        end
    end

    attr_reader :path, :content_type, :timeout

    def initialize(path, content_type:, timeout: Shell::DEFAULT_TIMEOUT)
      @path = File.expand_path(path.to_s) # absolute, so a name like "-x.pdf" can't pass for a tool option
      @content_type = self.class.normalize_content_type(content_type)
      @timeout = timeout
    end

    def call
      pages = Dir.mktmpdir("certtrack-text") do |dir|
        detected_type == PDF_TYPE ? read_pdf(dir) : read_image(dir)
      end
      Result.new(text: self.class.join_pages(pages), pages: pages)
    end

    Reading = Data.define(:text, :confidence, :words) # one tesseract run
    private_constant :Reading

    private

      def detected_type
        @detected_type ||= self.class.detect_content_type(path, content_type)
      end

      def read_pdf(dir)
        info = self.class.pdf_info(path, timeout: timeout)
        count = info.page_count
        raise Error, "The PDF has no pages" if count.zero?
        if count > MAX_PAGES
          raise Error, "The PDF has #{count} pages; the limit is #{MAX_PAGES}. Split it into smaller files and upload them."
        end

        (1..count).map do |number|
          layer = clean(Shell.run("pdftotext", "-layout", "-enc", "UTF-8", "-f", number, "-l", number, path, "-", timeout: timeout))
          next Page.new(number: number, text: layer, ocr: false) if self.class.usable?(layer)

          scanned = ocr(render_page(number, info.page_sizes[number - 1], dir), dir)
          if self.class.usable?(scanned) || self.class.meaningful_length(scanned) >= self.class.meaningful_length(layer)
            Page.new(number: number, text: scanned, ocr: true)
          else
            Page.new(number: number, text: layer, ocr: false)
          end
        end
      end

      def read_image(dir)
        png = File.join(dir, "image.png")
        self.class.load_image(path, max_side: MAX_OCR_SIDE).colourspace(:b_w).cast(:uchar).pngsave(png, compression: 1)
        [ Page.new(number: 1, text: ocr(png, dir), ocr: true) ]
      rescue Vips::Error => error
        raise Error, "The image could not be read: #{self.class.vips_error_detail(error)}"
      end

      # Rasterizes one PDF page to a grayscale PNG for tesseract; returns its path.
      def render_page(number, size, dir)
        prefix = File.join(dir, "page-#{number}")
        dpi = self.class.render_dpi(Array(size).max)
        Shell.run("pdftoppm", "-r", dpi, "-gray", "-f", number, "-l", number, "-singlefile", "-png", path, prefix,
          timeout: timeout)
        "#{prefix}.png"
      end

      # Tesseract's text for png, tried upside down too when unsure; "" when it is noise.
      def ocr(png, dir)
        reading = tesseract(png, dir)
        if reading.words.positive? && reading.confidence < RETRY_CONFIDENCE
          flipped = File.join(dir, "#{File.basename(png, '.png')}-flipped.png")
          Vips::Image.new_from_file(png).rot(:d180).pngsave(flipped, compression: 1)
          upside_down = tesseract(flipped, dir)
          reading = upside_down if upside_down.confidence > reading.confidence
        end
        reading.confidence < NOISE_CONFIDENCE ? "" : reading.text
      end

      # One tesseract run writing both plain text and per-word confidences (TSV).
      def tesseract(png, dir)
        base = File.join(dir, "ocr-#{SecureRandom.hex(6)}")
        Shell.run("tesseract", png, base, "-l", LANGUAGES, "-c", "tessedit_create_txt=1", "-c", "tessedit_create_tsv=1",
          timeout: timeout)
        confidence, words = word_confidence(read_output("#{base}.tsv"))
        Reading.new(text: clean(read_output("#{base}.txt")), confidence: confidence, words: words)
      end

      def read_output(file)
        File.exist?(file) ? File.read(file, mode: "rb") : ""
      end

      # Mean word confidence (0-100) weighted by letters and digits, and the word count.
      # Word rows are TSV level 5; specks read as "|" or "~" carry no letters, so they don't count.
      def word_confidence(tsv)
        weighted = total = words = 0
        tsv.dup.force_encoding(Encoding::UTF_8).scrub("").each_line do |line|
          fields = line.chomp.split("\t", 12)
          next unless fields.size == 12 && fields.first == "5"

          confidence = fields[10].to_f
          length = self.class.meaningful_length(fields[11])
          next if confidence.negative? || length.zero?

          weighted += confidence * length
          total += length
          words += 1
        end
        [ total.zero? ? 0.0 : weighted / total, words ]
      end

      # Valid UTF-8 without NULs or control characters (Postgres rejects NUL), no trailing
      # spaces, at most one blank line in a row, and no line that could pass for a page marker.
      def clean(text)
        text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
          .gsub(/[^\P{Cc}\n\t]/, "")
          .gsub(/[ \t]+$/, "")
          .gsub(/\n{3,}/, "\n\n")
          .gsub(PAGE_MARKER) { "== page #{Regexp.last_match(1)} ==" }
          .strip
      end
  end
end
