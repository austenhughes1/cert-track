require "vips"

module Certificates
  # Makes the stored copy of a certificate photo or scan (JPEG, PNG, WEBP, HEIC/HEIF): a JPEG
  # that fits within MAX_SIDE x MAX_SIDE pixels (never enlarged), upright (EXIF orientation
  # applied), sRGB, with any transparency flattened onto white, at quality 80. All other
  # metadata is dropped, including a phone's GPS location.
  #
  #   Certificates::ImageShrinker.write_jpeg(source_path, output_path) # => output_path
  #   Certificates::ImageShrinker.metadata?(source_path)               # => true for a phone photo
  #
  # Raises Certificates::ImageShrinker::Error for a file that isn't one of those formats or is
  # too large to open, and Vips::Error for one libvips can't read.
  module ImageShrinker
    MAX_SIDE = 2400 # px: every line of 8 pt and up on a card or letter page stayed readable in tests
    QUALITY = 80
    LOADERS = %w[jpegload pngload webpload heifload].freeze
    MAX_PIXELS = 200_000_000 # decompression-bomb guard, checked from the header
    # Header fields libvips fills from a file's EXIF, XMP and IPTC blocks and PNG text chunks
    # (ImageMagick keeps EXIF there): where a photo was taken, when, and on what phone.
    METADATA_FIELD = /\A(exif-data|xmp-data|iptc-data|png-comment-)/

    class Error < StandardError; end

    module_function

    # Whether the image carries metadata that write_jpeg would drop. Reads the header only.
    def metadata?(source)
      Vips::Image.new_from_file(source.to_s).get_fields.any? { |field| field.match?(METADATA_FIELD) }
    end

    def write_jpeg(source, output)
      header = Vips::Image.new_from_file(source.to_s)
      loader = header.get("vips-loader").to_s
      raise Error, "#{loader.presence || 'this'} is not a supported image format" unless LOADERS.any? { |name| loader.start_with?(name) }
      raise Error, "the image is too large (#{header.width} x #{header.height} pixels)" if header.width * header.height > MAX_PIXELS

      image = Vips::Image.thumbnail(source.to_s, MAX_SIDE, height: MAX_SIDE, size: :down) # also applies EXIF orientation
      # thumbnail converts CMYK itself but keeps other profiles (an iPhone's Display P3), and
      # strip drops the profile, so convert those first or the colours shift.
      image = image.icc_transform("srgb", embedded: true) if image.get_typeof("icc-profile-data").nonzero?
      image = image.colourspace(:srgb) # also makes 16-bit PNGs 8-bit
      image = image.flatten(background: 255) if image.has_alpha?
      image.jpegsave(output.to_s, Q: QUALITY, optimize_coding: true, strip: true)
      output
    end
  end
end
