require "test_helper"
require_relative "../../support/scanned_pdf"

class Imports::PageImagesTest < ActiveSupport::TestCase
  ORTIZ = ScannedPdf.certificate_text
  CHEN = ScannedPdf.certificate_text(name: "Flagger Certification", holder: "Li Chen", number: "FL-55501")

  setup { @dir = Dir.mktmpdir("page-images-test") }
  teardown { FileUtils.remove_entry(@dir) }

  test "renders one PDF page as a JPEG whose long side is 1568 px" do
    path = ScannedPdf.write_text_pdf(file("certs.pdf"), [ ORTIZ, CHEN ])

    jpeg = Imports::PageImages.render(path, content_type: "application/pdf", page: 2)

    image = Vips::Image.new_from_file(jpeg)
    assert_equal "jpegload", image.get("vips-loader")
    assert_equal 1568, [ image.width, image.height ].max
    assert_operator image.height, :>, image.width, "a letter page stays portrait"
    assert_includes ocr(jpeg), "Li Chen", "the requested page, readable"
  ensure
    File.delete(jpeg) if jpeg
  end

  test "a scanned PDF page and an oversized page stay within the limit" do
    scan = ScannedPdf.write(file("scan.pdf"), [ ORTIZ ])
    poster = ScannedPdf.write(file("poster.pdf"), [ Vips::Image.black(100, 4000).invert.copy(interpretation: :b_w) ], dpi: 10)

    [ scan, poster ].each do |path|
      Imports::PageImages.render(path, content_type: "application/pdf", page: 1) do |jpeg|
        image = Vips::Image.new_from_file(jpeg)
        assert_operator [ image.width, image.height ].max, :<=, 1568, path
      end
    end
  end

  test "photos are scaled down to the long side, never enlarged" do
    big = ScannedPdf.text_image(ORTIZ) # 2550 x 3300
    small = Vips::Image.black(800, 600).invert

    { big => [ 1212, 1568 ], small => [ 800, 600 ] }.each do |picture, size|
      picture.write_to_file(file("photo.png"))
      Imports::PageImages.render(file("photo.png"), content_type: "image/png") do |jpeg|
        image = Vips::Image.new_from_file(jpeg)
        assert_equal size, [ image.width, image.height ]
        assert_equal "jpegload", image.get("vips-loader")
      end
    end
  end

  test "max_long_side can be smaller" do
    path = ScannedPdf.write_text_pdf(file("certs.pdf"), [ ORTIZ ])
    ScannedPdf.text_image(ORTIZ).write_to_file(file("photo.webp"))

    { path => "application/pdf", file("photo.webp") => "image/webp" }.each do |source, type|
      Imports::PageImages.render(source, content_type: type, page: 1, max_long_side: 800) do |jpeg|
        image = Vips::Image.new_from_file(jpeg)
        assert_operator [ image.width, image.height ].max, :<=, 800, type
      end
    end
  end

  test "a phone photo is turned upright from its EXIF orientation, and its metadata is stripped" do
    upright = ScannedPdf.text_image(CHEN, page_points: [ 504, 216 ]) # landscape card
    stored = upright.rot(:d270).copy
    stored.set_type(GObject::GINT_TYPE, "orientation", 6)
    stored.jpegsave(file("IMG_0042.jpg"), Q: 90)
    assert_operator Vips::Image.new_from_file(file("IMG_0042.jpg")).height, :>, Vips::Image.new_from_file(file("IMG_0042.jpg")).width

    Imports::PageImages.render(file("IMG_0042.jpg"), content_type: "image/jpeg") do |jpeg|
      image = Vips::Image.new_from_file(jpeg)
      assert_operator image.width, :>, image.height, "landscape again"
      assert_equal 0, image.get_typeof("exif-data"), "EXIF (GPS, device) is not passed on"
      assert_includes ocr(jpeg), "Li Chen"
    end
  end

  test "HEIC photos become JPEGs" do
    skip "libvips has no HEIF loader" if Vips.type_find("VipsOperation", "heifload").zero?

    Imports::PageImages.render(file_fixture("imports/synthetic_certificate.heic"), content_type: "image/heic") do |jpeg|
      image = Vips::Image.new_from_file(jpeg)
      assert_equal "jpegload", image.get("vips-loader")
      assert_operator [ image.width, image.height ].max, :<=, 1568
    end
  end

  test "the block form deletes the JPEG afterwards and returns the block's value" do
    path = ScannedPdf.write_text_pdf(file("certs.pdf"), [ ORTIZ ])
    seen = nil

    value = Imports::PageImages.render(path, content_type: "application/pdf", page: 1) do |jpeg|
      seen = jpeg
      assert File.exist?(jpeg)
      :sent
    end

    assert_equal :sent, value
    assert_not File.exist?(seen)
  end

  test "the block form deletes the JPEG when the block raises" do
    path = ScannedPdf.write_text_pdf(file("certs.pdf"), [ ORTIZ ])
    seen = nil

    assert_raises(RuntimeError) do
      Imports::PageImages.render(path, content_type: "application/pdf", page: 1) { |jpeg| seen = jpeg; raise "model down" }
    end
    assert_not File.exist?(seen)
  end

  test "a page out of range raises ArgumentError and leaves no temp file" do
    path = ScannedPdf.write_text_pdf(file("certs.pdf"), [ ORTIZ, CHEN ])
    ScannedPdf.text_image(ORTIZ).write_to_file(file("photo.jpg"))

    assert_no_difference -> { leftovers } do
      assert_raises(ArgumentError) { Imports::PageImages.render(path, content_type: "application/pdf", page: 3) }
      assert_raises(ArgumentError) { Imports::PageImages.render(path, content_type: "application/pdf", page: 0) }
      assert_raises(ArgumentError) { Imports::PageImages.render(file("photo.jpg"), content_type: "image/jpeg", page: 2) }
    end
  end

  test "unsupported or unreadable files raise TextExtractor errors and leave no temp file" do
    File.write(file("notes.txt"), "not a certificate")
    File.write(file("broken.pdf"), "%PDF-1.4 nothing here")

    assert_no_difference -> { leftovers } do
      assert_raises(Imports::TextExtractor::UnsupportedType) { Imports::PageImages.render(file("notes.txt"), content_type: "text/plain") }
      assert_raises(Imports::TextExtractor::Error) { Imports::PageImages.render(file("broken.pdf"), content_type: "application/pdf") }
    end
  end

  private
    def file(name)
      File.join(@dir, name)
    end

    # Only this process's files (temp names hold the pid): parallel workers share /tmp.
    def leftovers
      Dir.glob(File.join(Dir.tmpdir, "certtrack-page*-#{Process.pid}-*")).size
    end

    def ocr(jpeg)
      Imports::Shell.run("tesseract", jpeg, "stdout", "-l", "eng")
    end
end
