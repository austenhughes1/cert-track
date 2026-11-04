require "test_helper"
require_relative "../../support/import_samples"

class Certificates::ImageShrinkerTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("image-shrinker-test-")
  end

  teardown do
    FileUtils.rm_rf(@dir)
  end

  test "a big photo fits within 2400 px as an sRGB JPEG at quality 80" do
    source = save(noise(3600, 2700), "photo.jpg", Q: 95)

    image = shrink(source)

    assert_equal [ 2400, 1800 ], [ image.width, image.height ]
    assert_equal "jpegload", image.get("vips-loader")
    assert_equal [ 3, :srgb ], [ image.bands, image.interpretation ]
    assert_operator File.size(output), :<, File.size(source) * 0.5
  end

  test "a small image is never enlarged" do
    image = shrink(save(noise(800, 600), "small.png"))

    assert_equal [ 800, 600 ], [ image.width, image.height ]
    assert_equal "jpegload", image.get("vips-loader")
  end

  test "EXIF orientation is applied and all metadata, GPS included, is dropped" do
    photo = noise(3000, 1500).copy
    photo.set_type(GObject::GINT_TYPE, "orientation", 6) # rotate 90 degrees clockwise to view
    photo.set_type(GObject::GSTR_TYPE, "exif-ifd3-GPSLatitude", "39/1 44/1 0/1")
    photo.set_type(GObject::GSTR_TYPE, "exif-ifd3-GPSLatitudeRef", "N")
    source = save(photo, "phone.jpg")
    assert_includes Vips::Image.new_from_file(source).get_fields, "exif-ifd3-GPSLatitude"

    image = shrink(source)

    assert_equal [ 1200, 2400 ], [ image.width, image.height ], "portrait once upright"
    assert_empty image.get_fields.grep(/exif|GPS|orientation|icc/)
  end

  test "metadata? is true for a photo with EXIF, and false once it is stripped" do
    photo = noise(300, 200).copy
    photo.set_type(GObject::GSTR_TYPE, "exif-ifd3-GPSLatitude", "39/1 44/1 0/1")
    source = save(photo, "phone.jpg")

    assert Certificates::ImageShrinker.metadata?(source)
    assert Certificates::ImageShrinker.metadata?(save(photo, "phone.webp"))
    assert_not Certificates::ImageShrinker.metadata?(save(photo, "clean.png", keep: :none))
    shrink(source)
    assert_not Certificates::ImageShrinker.metadata?(output)
  end

  test "transparency is flattened onto white" do
    ink = Vips::Image.black(600, 400).copy(interpretation: :srgb).bandjoin([ 0, 0 ]) # black RGB
    alpha = Vips::Image.black(600, 400).draw_rect(255, 0, 0, 300, 400, fill: true) # left half opaque
    source = save(ink.bandjoin(alpha).cast(:uchar).copy(interpretation: :srgb), "stamp.png")

    image = shrink(source)

    assert_equal 3, image.bands
    assert_operator image.getpoint(450, 200).min, :>=, 250, "transparent half is white"
    assert_operator image.getpoint(150, 200).max, :<=, 5, "opaque half stays black"
  end

  test "a wide-gamut photo (Display P3) is converted to sRGB, not just relabelled" do
    srgb = (Vips::Image.black(64, 32, bands: 3) + [ 200, 30, 30 ]).cast(:uchar).copy(interpretation: :srgb)
    source = save(srgb.icc_transform("p3", input_profile: "srgb"), "p3.jpg", Q: 100)
    assert_operator Vips::Image.new_from_file(source).getpoint(10, 10)[1], :>, 40, "P3 values differ from sRGB"

    red, green, blue = shrink(source).getpoint(10, 10)

    assert_in_delta 200, red, 6
    assert_in_delta 30, green, 6
    assert_in_delta 30, blue, 6
  end

  test "16-bit PNGs and grayscale scans become 8-bit sRGB JPEGs" do
    deep = ((Vips::Image.black(400, 300, bands: 3) + 40_000).cast(:ushort)).copy(interpretation: :rgb16)
    gray = (Vips::Image.black(400, 300) + 200).cast(:uchar).copy(interpretation: :b_w)

    [ save(deep, "deep.png"), save(gray, "gray.png") ].each do |source|
      image = shrink(source)
      assert_equal [ 3, :uchar ], [ image.bands, image.format ], source
    end
  end

  test "WEBP and HEIC become JPEGs" do
    sources = [ save(noise(500, 400), "photo.webp") ]
    sources << save(noise(500, 400), "photo.heic", compression: :hevc) if ImportSamples.heic_supported?

    sources.each do |source|
      image = shrink(source)
      assert_equal [ "jpegload", 500, 400 ], [ image.get("vips-loader"), image.width, image.height ], source
    end
  end

  test "a file that isn't a supported image is refused" do
    error = assert_raises(Certificates::ImageShrinker::Error) { shrink(save(noise(40, 30), "scan.tif")) }
    assert_match "tiffload is not a supported image format", error.message

    assert_raises(Vips::Error) { shrink(file_fixture("notes.txt").to_s) }
  end

  test "an image too big to open is refused from its header" do
    source = File.join(@dir, "bomb.png")
    File.binwrite(source, claimed_png(20_000, 20_000)) # 400 megapixels claimed

    error = assert_raises(Certificates::ImageShrinker::Error) { shrink(source) }
    assert_match "too large", error.message
  end

  private
    def output
      File.join(@dir, "out.jpg")
    end

    def shrink(source)
      assert_equal output, Certificates::ImageShrinker.write_jpeg(source, output)
      Vips::Image.new_from_file(output)
    end

    def save(image, name, **options)
      File.join(@dir, name).tap { |path| image.write_to_file(path, **options) }
    end

    # Random pixels don't compress, like the detail in a phone photo.
    def noise(width, height)
      Vips::Image.gaussnoise(width, height, mean: 128, sigma: 40).bandjoin([ Vips::Image.gaussnoise(width, height, mean: 100, sigma: 30) ] * 2)
        .cast(:uchar).copy(interpretation: :srgb)
    end

    # A tiny 8-bit RGB PNG whose header claims width x height; its pixel data is a few bytes.
    def claimed_png(width, height)
      chunk = ->(type, data) { [ data.bytesize ].pack("N") + type.b + data.b + [ Zlib.crc32(type.b + data.b) ].pack("N") }
      "\x89PNG\r\n\x1A\n".b + chunk.("IHDR", [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC")) +
        chunk.("IDAT", Zlib::Deflate.deflate("\0" * 100)) + chunk.("IEND", "")
    end
end
