require "vips"

module Imports
  # Renders one page of an import file as a JPEG for the vision model: the step 4 fallback
  # when a page's OCR text is not usable (Imports::TextExtractor.usable?). The long side is
  # at most max_long_side pixels (1568 by default, PLAN.md); smaller pages are not enlarged.
  #
  #   jpeg = Imports::PageImages.render(path, content_type: "application/pdf", page: 2)
  #   ...                                    # the caller deletes jpeg (File.delete)
  #
  #   Imports::PageImages.render(path, content_type: "image/heic", page: 1) do |jpeg|
  #     send_to_model(File.binread(jpeg))    # deleted when the block returns
  #   end
  #
  # PDF pages are rendered with pdftoppm straight to the target size (vector text stays
  # sharp, oversized pages can't blow up memory); images are turned upright from their EXIF
  # orientation and scaled down with libvips. Metadata (GPS and the like) is stripped.
  # Raises ArgumentError for a page out of range, TextExtractor::Error / UnsupportedType
  # for unreadable files, or an Imports::Shell::Error.
  class PageImages
    DEFAULT_MAX_LONG_SIDE = 1568
    JPEG_QUALITY = 85

    # Extended rather than defined on the singleton, so a test that overrides render on
    # the class and then removes its override gets this one back.
    module Rendering
      def render(path, content_type:, page: 1, max_long_side: DEFAULT_MAX_LONG_SIDE, timeout: Shell::DEFAULT_TIMEOUT)
        jpeg = new(path, content_type: content_type, page: page, max_long_side: max_long_side, timeout: timeout).call
        return jpeg unless block_given?

        begin
          yield jpeg
        ensure
          FileUtils.rm_f(jpeg)
        end
      end
    end
    extend Rendering

    attr_reader :path, :content_type, :page, :max_long_side, :timeout

    def initialize(path, content_type:, page: 1, max_long_side: DEFAULT_MAX_LONG_SIDE, timeout: Shell::DEFAULT_TIMEOUT)
      @path = File.expand_path(path.to_s) # absolute, so a name like "-x.pdf" can't pass for a tool option
      @content_type = TextExtractor.detect_content_type(@path, content_type)
      @page = Integer(page || 1)
      @max_long_side = Integer(max_long_side)
      @timeout = timeout
      raise ArgumentError, "max_long_side must be positive" unless @max_long_side.positive?
    end

    # Writes the JPEG to a new temp file and returns its path.
    def call
      output = new_output_path
      Dir.mktmpdir("certtrack-page") do |dir|
        image = content_type == TextExtractor::PDF_TYPE ? pdf_page(dir) : image_page
        save_jpeg(image, output)
      end
      output
    rescue StandardError
      FileUtils.rm_f(output) if output
      raise
    end

    private
      def pdf_page(dir)
        count = TextExtractor.page_count(path, timeout: timeout)
        raise ArgumentError, "page #{page} is out of range (the PDF has #{count} pages)" unless page.between?(1, count)

        prefix = File.join(dir, "page")
        Shell.run("pdftoppm", "-f", page, "-l", page, "-singlefile", "-scale-to", max_long_side, "-png", path, prefix,
          timeout: timeout)
        thumbnail("#{prefix}.png")
      end

      def image_page
        raise ArgumentError, "page #{page} is out of range (an image has 1 page)" unless page == 1

        TextExtractor.load_image(path, max_side: max_long_side)
      end

      def thumbnail(file)
        Vips::Image.thumbnail(file, max_long_side, height: max_long_side, size: :down)
      end

      def save_jpeg(image, output)
        image = image.flatten(background: 255) if image.has_alpha?
        image.colourspace(:srgb).jpegsave(output, Q: JPEG_QUALITY, strip: true)
      rescue Vips::Error => error
        raise TextExtractor::Error, "The page image could not be made: #{TextExtractor.vips_error_detail(error)}"
      end

      def new_output_path
        file = Tempfile.create([ "certtrack-page-", ".jpg" ])
        file.close
        file.path
      end
  end
end
