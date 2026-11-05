require "vips"

module Certificates
  # Reads the QR codes on a certificate file locally with ZBar's zbarimg (docs/PLAN.md, Phase 3b).
  # Nothing leaves the machine. Only the QR symbology is enabled, so no other barcode (such as the
  # PDF417 on the back of a driver's license) is ever decoded.
  #
  #   Certificates::QrReader.new(path, content_type: "application/pdf").call
  #   # => [{ "page" => 2, "text" => "https://www.redcross.org/take-a-class/qrcode?certnumber=..." }]
  #   Certificates::QrReader.available? # => false when zbarimg (zbar-tools) is not installed
  #
  # Each page is read as it is; when nothing decodes, it is read again at 2x, then 3x: ZBar misses
  # small QR codes that it reads once they are bigger. A PDF page (the first max_pages) is rendered
  # in grayscale by pdftoppm at RENDER_DPI, and again at 2x and 3x that dpi, which brings out detail
  # an enlarged copy can't. An image (JPEG, PNG, WebP, HEIC/HEIF) is turned upright from its EXIF
  # orientation and made grayscale with libvips, then enlarged by libvips. A page is read at most at
  # MAX_SCAN_PIXELS. zbarimg only ever reads these page images, never the uploaded file itself.
  #
  # Codes come back in page order, each page and text once; page numbers are those of this file.
  # After call, undecoded_pages lists the pages that decoded nothing where a QR code seems to be
  # there anyway (Certificates::QrFinder): too small or blurry to read.
  # Never raises for a file it can't read (unsupported, corrupt, password-protected, a tool failing
  # or timing out): it logs a warning, without anything read from the file, and returns what it
  # read so far, usually []. Without zbarimg it returns [] and logs that once.
  class QrReader
    COMMAND = "zbarimg".freeze
    # XML output keeps a QR text that holds line breaks in one piece and names each code's symbology.
    ZBAR_OPTIONS = %w[--nodbus --xml -q -Sdisable -Sqrcode.enable].freeze
    ZBAR_NAMESPACE = { "zbar" => "http://zbar.sourceforge.net/2008/barcode" }.freeze
    QR_SYMBOL = "QR-Code".freeze
    NOTHING_FOUND_EXIT = 4 # zbarimg's exit status for an image without a code

    MAX_PAGES = 30 # a certificate is a page or two; a long PDF's later pages aren't read
    RENDER_DPI = 150 # then 300 and 450 for a page that reads nothing
    SCALES = [ 2, 3 ].freeze # tried in turn while a page reads nothing
    MIN_SCALE_STEP = 0.5 # a capped scale this close to the one before it is skipped
    MAX_SIDE = 6_000 # px: bigger photos are scaled down first
    # zbarimg takes about 10 bytes a pixel: about 400 MB at the cap.
    MAX_SCAN_PIXELS = MAX_SIDE * MAX_SIDE
    LOG_TAG = "[Certificates::QrReader]".freeze

    class << self
      # Whether zbarimg is on PATH and runs.
      def available?
        Imports::Shell.run(COMMAND, "--version", timeout: 10)
        true
      rescue Imports::Shell::Error
        false
      end

      # Logs the missing tool once per process.
      def warn_unavailable
        return if @warned_unavailable

        @warned_unavailable = true
        Rails.logger.warn("#{LOG_TAG} #{COMMAND} is not installed, so QR codes are not read. Install zbar-tools.")
      end

      def reset_unavailable_warning!
        @warned_unavailable = false
      end
    end

    attr_reader :path, :content_type, :timeout, :max_pages, :undecoded_pages

    # timeout: seconds each tool call may take.
    def initialize(path, content_type:, timeout: Imports::Shell::DEFAULT_TIMEOUT, max_pages: MAX_PAGES)
      @path = File.expand_path(path.to_s) # absolute, so a name like "-x.pdf" can't pass for a tool option
      @content_type = content_type
      @timeout = timeout
      @max_pages = max_pages
      @undecoded_pages = []
    end

    # [{ "page" => Integer, "text" => String }, ...]
    def call
      codes = []
      unless self.class.available?
        self.class.warn_unavailable
        return codes
      end

      Dir.mktmpdir("certtrack-qr") do |dir|
        each_page(dir) do |number, render|
          read_page(render, number).each { |text| codes << { "page" => number, "text" => text } }
        end
      end
      codes.uniq
    rescue StandardError => error
      log_warning("QR codes not read", error)
      codes.uniq
    end

    private
      # Yields [page number, render] for each page. render.call(scale) writes the page's grayscale
      # image at that scale and returns its path: a PNG at 1x (libvips reads it back; Active Storage
      # blocks its untrusted loaders, PPM among them), else an uncompressed PGM, which only zbarimg
      # reads and is much quicker to write this big.
      def each_page(dir, &block)
        if Imports::TextExtractor.detect_content_type(path, content_type) == Imports::TextExtractor::PDF_TYPE
          each_pdf_page(dir, &block)
        else
          image = File.join(dir, "image.png")
          upright = Imports::TextExtractor.load_image(path, max_side: MAX_SIDE)
          upright.colourspace(:srgb).colourspace(:b_w).cast(:uchar).pngsave(image, compression: 1) # via sRGB: 16-bit becomes 8-bit
          yield 1, ->(scale) { scale == 1 ? image : enlarge(image, scale, dir) }
        end
      end

      def each_pdf_page(dir)
        info = Imports::TextExtractor.pdf_info(path, timeout: timeout)
        if info.page_count > max_pages
          Rails.logger.info("#{LOG_TAG} QR codes read on the first #{max_pages} of #{info.page_count} pages only")
        end

        (1..[ info.page_count, max_pages ].min).each do |number|
          dpi = Imports::TextExtractor.render_dpi(Array(info.page_sizes[number - 1]).max, preferred: RENDER_DPI)
          yield number, ->(scale) { render_pdf_page(number, dpi * scale, dir, png: scale == 1) }
        rescue Imports::Shell::Error, Vips::Error, Nokogiri::XML::SyntaxError => error
          log_warning("QR codes not read on page #{number}", error) # the other pages still are
        end
      end

      def render_pdf_page(number, dpi, dir, png:)
        prefix = File.join(dir, "page-#{number}-#{dpi.floor}")
        Imports::Shell.run("pdftoppm", "-r", dpi.floor, "-gray", "-f", number, "-l", number, "-singlefile",
          *("-png" if png), path, prefix, timeout: timeout)
        "#{prefix}.#{png ? 'png' : 'pgm'}"
      end

      def enlarge(image, scale, dir)
        enlarged = File.join(dir, "enlarged-#{scale}.pgm")
        Vips::Image.new_from_file(image).resize(scale).ppmsave(enlarged)
        enlarged
      end

      # The QR texts on one page: as it is, else at 2x, else at 3x. Its images are deleted after.
      def read_page(render, number)
        image = render.call(1)
        texts = decode(image)
        return texts if texts.any?

        header = Vips::Image.new_from_file(image)
        scales_for(header.width * header.height).each do |scale|
          bigger = render.call(scale)
          texts = decode(bigger)
          return texts if texts.any?
        ensure
          FileUtils.rm_f(bigger) if bigger
        end
        @undecoded_pages << number if QrFinder.new(image).present?
        []
      ensure
        FileUtils.rm_f(image) if image
      end

      # SCALES, each capped so the page stays within MAX_SCAN_PIXELS. A capped scale that adds
      # little to the size before it (1x, or the scale before) is left out.
      def scales_for(pixels)
        limit = Math.sqrt(MAX_SCAN_PIXELS.fdiv([ pixels, 1 ].max)).floor(2)
        SCALES.each_with_object([]) do |scale, kept|
          scale = [ scale, limit ].min
          kept << scale if scale >= (kept.last || 1) + MIN_SCALE_STEP
        end
      end

      # The QR texts zbarimg decodes in an image, in its order.
      def decode(image)
        parse(Imports::Shell.run(COMMAND, *ZBAR_OPTIONS, image, timeout: timeout))
      rescue Imports::Shell::Failed => error
        raise unless error.exit_status == NOTHING_FOUND_EXIT

        []
      end

      # zbarimg's XML: each text in a CDATA block, base64-encoded when it holds bytes that would
      # break the XML.
      def parse(xml)
        return [] if xml.blank?

        document = Nokogiri::XML(xml) { |config| config.strict.nonet }
        document.xpath("//zbar:symbol[@type='#{QR_SYMBOL}']/zbar:data", ZBAR_NAMESPACE).filter_map do |data|
          clean(data["format"] == "base64" ? Base64.decode64(data.text) : data.text)
        end.uniq
      end

      # Valid UTF-8 without control characters (line breaks and tabs stay); nil when blank.
      def clean(text)
        text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("").gsub(/[^\P{Cc}\n\t]/, "").strip.presence
      end

      # Says what failed, never what the file holds. Tool messages name temp files: removed.
      def log_warning(message, error)
        detail = Imports::TextExtractor.redact_paths(error.message.to_s.lines.first.to_s.strip).truncate(200)
        Rails.logger.warn("#{LOG_TAG} #{message}: #{error.class.name}: #{detail}")
      end
  end
end
