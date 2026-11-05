require "test_helper"
require "vips"

class Certificates::QrFinderTest < ActiveSupport::TestCase
  setup { @dir = Dir.mktmpdir("qr-finder-test") }
  teardown { FileUtils.remove_entry(@dir) }

  test "finds a QR code, whichever one" do
    %w[redcross_qr redcross_small_qr 360training_qr lookalike_qr unrelated_qr].each do |name|
      assert present?(file_fixture("qr/#{name}.png")), name
    end
  end

  test "a barcode, plain paper and text aren't a QR code" do
    assert_not present?(file_fixture("qr/code128.png"))
    assert_not present?(page(1000, 700, 255))
    assert_not present?(text_page)
  end

  test "a code shrunk to a square of fine noise, its corner marks gone, is still seen" do
    modules = (Vips::Image.gaussnoise(35, 35, mean: 128, sigma: 80, seed: 1) > 128).cast(:uchar)
    tiny = modules.resize(2, kernel: :nearest).gaussblur(0.6)
    path = File.join(@dir, "tiny.png")
    (Vips::Image.black(945, 1000) + 255).cast(:uchar).insert(tiny, 400, 500).cast(:uchar).pngsave(path)

    assert present?(path)
  end

  test "a large photo-like block is not a shrunken code" do
    noise = Vips::Image.gaussnoise(400, 400, mean: 128, sigma: 40, seed: 1).cast(:uchar)
    path = File.join(@dir, "photo.png")
    (Vips::Image.black(1000, 1000) + 255).cast(:uchar).insert(noise, 100, 100).cast(:uchar).pngsave(path)

    assert_not present?(path)
  end

  test "an unreadable image is not found, without raising" do
    path = File.join(@dir, "broken.png")
    File.write(path, "not an image")

    assert_not present?(path)
  end

  private
    def present?(path)
      Certificates::QrFinder.new(path).present?
    end

    def page(width, height, value)
      path = File.join(@dir, "page-#{width}-#{value}.png")
      (Vips::Image.black(width, height) + value).cast(:uchar).pngsave(path)
      path
    end

    def text_page
      path = File.join(@dir, "text.png")
      Vips::Image.text("Certificate of Completion\nJuan A. Ortiz\nAdult First Aid/CPR/AED\nDate Completed: 3/14/2025", dpi: 300)
        .invert.cast(:uchar).pngsave(path)
      path
    end
end
