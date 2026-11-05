require "test_helper"
require_relative "../../support/scanned_pdf"

class Certificates::QrReaderTest < ActiveSupport::TestCase
  REDCROSS_LINK = "https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123".freeze

  setup do
    skip "zbarimg is not installed (apt install zbar-tools); CI has it" unless Certificates::QrReader.available?
    @dir = Dir.mktmpdir("qr-reader-test")
  end

  teardown { FileUtils.remove_entry(@dir) if @dir }

  test "reads the QR code on an image" do
    assert_equal [ { "page" => 1, "text" => REDCROSS_LINK } ], read(qr_fixture("redcross_qr.png"), "image/png")
  end

  test "a QR code's text comes back as decoded, whatever site it points to" do
    assert_equal [ "https://example.com/brochure" ], texts(read(qr_fixture("unrelated_qr.png"), "image/png"))
    assert_equal [ "https://redcross-verify.com/certificate?certnumber=TEST123" ], texts(read(qr_fixture("lookalike_qr.png"), "image/png"))
    assert_match %r{\Ahttps://verify\.360training\.com/qrcode-certificate-validation\?enrollmentId=12345678&},
      texts(read(qr_fixture("360training_qr.png"), "image/png")).sole
  end

  test "a PDF's codes carry the number of the page they are on" do
    assert_equal [ { "page" => 2, "text" => REDCROSS_LINK } ], read(qr_fixture("two_pages_qr_on_2.pdf"), "application/pdf")
  end

  test "a JPEG photo with an EXIF orientation and a WebP are read" do
    photo = Vips::Image.new_from_file(qr_fixture("redcross_qr.png")).colourspace(:srgb)
    photo.rot(:d90).copy.tap { |image| image.set_type(GObject::GINT_TYPE, "orientation", 8) }.jpegsave(file("IMG_0042.jpg"), Q: 90)
    photo.webpsave(file("card.webp"), lossless: true)

    assert_equal [ REDCROSS_LINK ], texts(read(file("IMG_0042.jpg"), "image/jpeg"))
    assert_equal [ REDCROSS_LINK ], texts(read(file("card.webp"), "image/webp"))
  end

  test "a QR code too small to read as it is is read once enlarged" do
    path, plain = small_qr_image
    skip "no downscaled copy of the QR code misses as it is and reads enlarged with this libvips and ZBar" if path.nil?
    assert_empty plain, "a single zbarimg pass reads nothing in it"

    assert_equal [ { "page" => 1, "text" => REDCROSS_LINK } ], read(path, "image/png")
  end

  test "a page that reads nothing is tried at 2x, then 3x, then given up" do
    blank = Vips::Image.black(850, 1100).invert.cast(:uchar).copy(interpretation: :b_w)
    blank.pngsave(file("blank.png"))
    File.binwrite(file("blank.pdf"), ScannedPdf.image_pdf([ [ blank, ScannedPdf.jpeg_bytes(blank) ] ] * 2, dpi: 100))

    image, image_scales = recording_reader(file("blank.png"), "image/png")
    pdf, pdf_scales = recording_reader(file("blank.pdf"), "application/pdf")

    assert_equal [], image.call
    assert_equal [ 2, 3 ], image_scales
    assert_equal [], pdf.call
    assert_equal [ 2, 3, 2, 3 ], pdf_scales, "each page"
  end

  test "a small QR code on a scanned PDF page is read from the page rendered at a higher dpi" do
    File.binwrite(file("scan.pdf"), small_qr_scan(inches: 0.3))
    Imports::Shell.run("pdftoppm", "-r", Certificates::QrReader::RENDER_DPI, "-gray", "-singlefile", "-png", file("scan.pdf"), file("page"))
    skip "the QR code read at #{Certificates::QrReader::RENDER_DPI} dpi with this poppler and ZBar" if plain_zbar(file("page.png")).present?

    reader, scales = recording_reader(file("scan.pdf"), "application/pdf")

    assert_equal [ { "page" => 1, "text" => REDCROSS_LINK } ], reader.call
    assert_includes [ [ 2 ], [ 2, 3 ] ], scales
  end

  test "enlarging stops at the first scale that reads a code" do
    path, = small_qr_image
    skip "no downscaled copy of the QR code misses as it is and reads enlarged with this libvips and ZBar" if path.nil?

    reader, scales = recording_reader(path, "image/png")

    assert_equal [ REDCROSS_LINK ], texts(reader.call)
    assert_includes [ [ 2 ], [ 2, 3 ] ], scales
  end

  test "a big page is enlarged no further than MAX_SCAN_PIXELS, and not at all when already that big" do
    reader = Certificates::QrReader.new(qr_fixture("redcross_qr.png"), content_type: "image/png")
    scales = ->(width, height) { reader.send(:scales_for, width * height) }

    assert_equal [ 2, 3 ], scales.(1650, 1275), "a letter page at 150 dpi"
    assert_equal [ 2, 2.88 ], scales.(2400, 1800)
    assert_equal [ 2 ], scales.(3000, 2000), "3x would be capped at 2.44x, too close to 2x"
    assert_equal [ 1.71 ], scales.(4032, 3024), "a 12 MP phone photo"
    assert_equal [], scales.(5000, 3600), "1.41x adds too little"
  end

  test "other barcodes, such as a Code 128, are never decoded" do
    plain = Imports::Shell.run("zbarimg", "--nodbus", "-q", qr_fixture("code128.png"))
    assert_equal "CODE-128:TEST-0001", plain.strip, "the fixture is a real barcode"

    assert_equal [], read(qr_fixture("code128.png"), "image/png")
  end

  test "each page and text comes back once, in page order" do
    page = Vips::Image.new_from_file(qr_fixture("redcross_qr.png"))
    pdf = ScannedPdf.image_pdf(Array.new(3) { [ page, ScannedPdf.jpeg_bytes(page) ] }, dpi: 150)
    File.binwrite(file("three.pdf"), pdf)

    assert_equal [ 1, 2, 3 ].map { |number| { "page" => number, "text" => REDCROSS_LINK } }, read(file("three.pdf"), "application/pdf")
  end

  test "only the first max_pages pages of a PDF are read" do
    page = Vips::Image.new_from_file(qr_fixture("redcross_qr.png"))
    File.binwrite(file("three.pdf"), ScannedPdf.image_pdf(Array.new(3) { [ page, ScannedPdf.jpeg_bytes(page) ] }, dpi: 150))

    codes = Certificates::QrReader.new(file("three.pdf"), content_type: "application/pdf", max_pages: 2).call

    assert_equal [ 1, 2 ], codes.map { |code| code["page"] }
  end

  test "an unreadable or unsupported file reads nothing and logs a warning without its contents" do
    File.write(file("broken.pdf"), "%PDF-1.4 SECRET-NAME not really a pdf")
    File.write(file("notes.txt"), "SECRET-NAME")
    log = StringIO.new

    with_logger(log) do
      assert_equal [], read(file("broken.pdf"), "application/pdf")
      assert_equal [], read(file("notes.txt"), "text/plain")
      assert_equal [], read(file("missing.png"), "image/png")
    end

    assert_equal 3, log.string.scan("[Certificates::QrReader] QR codes not read").size, log.string
    assert_no_match "SECRET-NAME", log.string
    assert_no_match @dir, log.string, "no server paths"
  end

  test "a timed-out zbarimg reads nothing and does not raise" do
    reader = Certificates::QrReader.new(qr_fixture("redcross_qr.png"), content_type: "image/png", timeout: 0.000_1)

    assert_nothing_raised { assert_equal [], reader.call }
  end

  test "without zbarimg nothing is read, and that is logged once" do
    log = StringIO.new
    Certificates::QrReader.reset_unavailable_warning!

    with_path(@dir) do
      assert_not Certificates::QrReader.available?
      with_logger(log) do
        2.times { assert_equal [], read(qr_fixture("redcross_qr.png"), "image/png") }
      end
    end

    assert_equal 1, log.string.scan("zbarimg is not installed").size, log.string
    assert Certificates::QrReader.available?, "PATH is restored"
  ensure
    Certificates::QrReader.reset_unavailable_warning!
  end

  private
    def read(path, content_type)
      Certificates::QrReader.new(path, content_type: content_type).call
    end

    def texts(codes)
      codes.map { |code| code["text"] }
    end

    def qr_fixture(name)
      file_fixture("qr/#{name}").to_s
    end

    def file(name)
      File.join(@dir, name)
    end

    # A downscaled copy of redcross_qr.png that a single zbarimg pass can't read but an enlarged
    # copy can, and that single pass's output. ZBar's reading of a tiny QR code is very sensitive
    # to the exact pixels, which differ between libvips and ZBar versions, so the first of a few
    # candidates that qualifies is used (each one does with libvips 8.18 and ZBar 0.23.92).
    def small_qr_image
      source = Vips::Image.new_from_file(qr_fixture("redcross_qr.png"))
      [ [ 0.27, :linear ], [ 0.24, :linear ], [ 0.28, :cubic ], [ 0.26, :cubic ] ].each do |scale, kernel|
        path = file("small-#{scale}-#{kernel}.png")
        small = source.resize(scale, kernel: kernel).tap { |image| image.pngsave(path) }
        plain = plain_zbar(path)
        next if plain.present?

        enlarged = file("small-enlarged.png")
        readable = [ 2, 3 ].any? do |factor|
          small.resize(factor).pngsave(enlarged)
          plain_zbar(enlarged).present?
        end
        return [ path, plain ] if readable
      end
      nil
    end

    def plain_zbar(path)
      Imports::Shell.run("zbarimg", *Certificates::QrReader::ZBAR_OPTIONS, path)
    rescue Imports::Shell::Failed
      ""
    end

    # A reader that records the scales it reads pages at, beyond 1x.
    def recording_reader(path, content_type)
      scales = []
      reader = Certificates::QrReader.new(path, content_type: content_type)
      reader.singleton_class.prepend(Module.new do
        define_method(:read_page) do |render|
          super(->(scale) { scales << scale unless scale == 1; render.call(scale) })
        end
      end)
      [ reader, scales ]
    end

    # A letter page scanned at 400 dpi into an image-only PDF, with redcross_small_qr.png's code
    # (33 modules and a 4-module margin, 1 px each) printed `inches` wide near the top left.
    def small_qr_scan(inches:, dpi: 400)
      code = Vips::Image.new_from_file(qr_fixture("redcross_small_qr.png")).crop(22, 22, 41, 41)
      code = code.resize((inches * dpi).round.fdiv(code.width), kernel: :nearest)
      page = Vips::Image.black(8.5 * dpi, 11 * dpi).invert.cast(:uchar).insert(code, dpi, dpi).copy(interpretation: :b_w)
      ScannedPdf.image_pdf([ [ page, ScannedPdf.jpeg_bytes(page, quality: 75) ] ], dpi: dpi)
    end

    def with_path(path)
      previous = ENV["PATH"]
      ENV["PATH"] = path
      yield
    ensure
      ENV["PATH"] = previous
    end

    def with_logger(io)
      previous = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      yield
    ensure
      Rails.logger = previous
    end
end
