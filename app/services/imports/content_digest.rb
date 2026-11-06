require "vips"

module Imports
  # A fingerprint of what a file shows rather than its bytes: the decoded pixels of an image (turned
  # upright), or a PDF's pages rendered in grayscale. A copy that was re-saved, had its metadata
  # stripped or was re-exported has a different sha256 but the same digest, so it needn't be read
  # again (Imports::ExtractTextJob). All of it stays on the machine.
  #
  #   Imports::ContentDigest.new(path, content_type: "image/png").call # => "9f2c..." or nil
  #
  # It is deliberately exact: only the same pixels match. A "looks similar" match could take two
  # people's certificates of one template for the same one, and a certificate must never be left out
  # unless it is verified fake. So a photo that was resized or recompressed still gets read. nil when
  # the file can't be read: the text step then reports why.
  class ContentDigest
    RENDER_DPI = 100
    MAX_SIDE = 6_000 # px, as Certificates::QrReader reads images
    MAX_PAGES = 200

    def initialize(path, content_type:, timeout: Imports::Shell::DEFAULT_TIMEOUT)
      @path = File.expand_path(path.to_s)
      @content_type = content_type
      @timeout = timeout
    end

    def call
      if TextExtractor.detect_content_type(@path, @content_type) == TextExtractor::PDF_TYPE
        pdf_digest
      else
        image_digest
      end
    rescue TextExtractor::Error, Shell::Error, Vips::Error, Nokogiri::XML::SyntaxError => error
      Rails.logger.info("[Imports::ContentDigest] not computed: #{error.class.name}")
      nil
    end

    private
      def image_digest
        image = TextExtractor.load_image(@path, max_side: MAX_SIDE).colourspace(:srgb).cast(:uchar)
        Digest::SHA256.hexdigest("#{image.width}x#{image.height}x#{image.bands}\n#{image.write_to_memory}")
      end

      # A PDF too long to be a certificate pack isn't fingerprinted: its sha256 still catches a copy.
      def pdf_digest
        pages = TextExtractor.pdf_info(@path, timeout: @timeout).page_count
        return if pages.zero? || pages > MAX_PAGES

        Dir.mktmpdir("certtrack-digest") do |dir|
          Shell.run("pdftoppm", "-r", RENDER_DPI, "-gray", @path, File.join(dir, "page"), timeout: @timeout)
          digest = Digest::SHA256.new
          Dir[File.join(dir, "page*.pgm")].sort.each { |page| digest.update(File.binread(page)) }
          digest.hexdigest
        end
      end
  end
end
