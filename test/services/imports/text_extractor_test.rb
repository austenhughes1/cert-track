require "test_helper"
require_relative "../../support/scanned_pdf"

# Runs the real tools (pdfinfo, pdftotext, pdftoppm, tesseract, libvips) on synthetic files
# generated per test. Every name and number is made up.
class Imports::TextExtractorTest < ActiveSupport::TestCase
  ORTIZ = ScannedPdf.certificate_text
  CHEN = ScannedPdf.certificate_text(name: "Flagger Certification", holder: "Li Chen", number: "FL-55501",
    completed: "2024-11-02", expires: "2027-11-02")
  OUTLINE = "COURSE OUTLINE\nModule 1: Hazard recognition and fall protection basics\nModule 2: Ladders and scaffolds"
  CARD = [ 504, 216 ].freeze # a 7 x 3 inch card in points: quicker to OCR than a letter page

  setup { @dir = Dir.mktmpdir("text-extractor-test") }
  teardown { FileUtils.remove_entry(@dir) }

  test "a text PDF is read page by page from its text layer, with page markers" do
    path = ScannedPdf.write_text_pdf(file("certs.pdf"), [ ORTIZ, CHEN ])

    result = extract(path, "application/pdf")

    assert_equal [ 1, 2 ], result.pages.map(&:number)
    assert_equal [ false, false ], result.pages.map(&:ocr)
    assert_includes result.pages.first.text, "Awarded to: Juan A. Ortiz"
    assert_includes result.pages.second.text, "Awarded to: Li Chen"
    assert_not_includes result.pages.first.text, "Li Chen"
    assert result.text.start_with?("=== page 1 ===\nCERTIFICATE OF COMPLETION\n")
    assert_match(/Training LLC\n\n=== page 2 ===\nCERTIFICATE OF COMPLETION\n/, result.text)
    assert_equal result.text, Imports::TextExtractor.join_pages(result.pages)
  end

  test "a scanned PDF has no text layer, so each page is rasterized and read by tesseract" do
    path = ScannedPdf.write(file("scan.pdf"), [ ORTIZ, CHEN ])
    assert_operator Imports::Shell.run("pdftotext", "-layout", "-f", 1, "-l", 1, path, "-").strip.length, :<,
      Imports::Config.ocr_min_chars, "the synthetic scan must have no usable text layer"

    result = extract(path, "application/pdf")

    assert_equal [ true, true ], result.pages.map(&:ocr)
    assert_includes result.pages.first.text, "Juan A. Ortiz"
    assert_includes result.pages.first.text, "Certificate No: 30-1234567"
    assert_includes result.pages.second.text, "Li Chen"
    assert_includes result.pages.second.text, "Expires: 2027-11-02"
    assert result.text.start_with?("=== page 1 ===\nCERTIFICATE OF COMPLETION")
  end

  test "a mixed PDF keeps the text layer where there is one and OCRs the scanned page" do
    text_pdf = ScannedPdf.write_text_pdf(file("outline.pdf"), [ OUTLINE ])
    scan = ScannedPdf.write(file("scan.pdf"), [ ORTIZ ])
    path = ScannedPdf.combine(file("mixed.pdf"), text_pdf, scan)

    result = extract(path, "application/pdf")

    assert_equal [ [ 1, false ], [ 2, true ] ], result.pages.map { |page| [ page.number, page.ocr ] }
    assert_includes result.pages.first.text, "COURSE OUTLINE"
    assert_includes result.pages.second.text, "Awarded to: Juan A. Ortiz"
    assert_match(/=== page 1 ===\nCOURSE OUTLINE.*=== page 2 ===\nCERTIFICATE OF COMPLETION/m, result.text)
  end

  test "an upside-down scan with no EXIF orientation is turned over and read" do
    path = ScannedPdf.write(file("upside-down.pdf"), [ ScannedPdf.text_image(CHEN, page_points: CARD).rot(:d180) ])

    page = extract(path, "application/pdf").pages.sole

    assert page.ocr
    assert_includes page.text, "Awarded to: Li Chen"
  end

  test "JPEG, PNG and WebP photos are read by tesseract as one page" do
    image = ScannedPdf.text_image(ORTIZ, page_points: CARD)
    { "photo.jpg" => "image/jpeg", "photo.png" => "image/png", "photo.webp" => "image/webp" }.each do |name, type|
      image.write_to_file(file(name))

      result = extract(file(name), type)

      assert_equal 1, result.pages.sole.number, name
      assert result.pages.sole.ocr, name
      assert_includes result.text, "Awarded to: Juan A. Ortiz", name
      assert result.text.start_with?("=== page 1 ===\nCERTIFICATE OF COMPLETION"), name
    end
  end

  test "an iPhone HEIC photo is decoded by libvips and read" do
    skip_unless_heif
    result = extract(file_fixture("imports/synthetic_certificate.heic"), "image/heic")

    assert_includes result.text, "Awarded to: Maria L. Example"
    assert_includes result.text, "Expires: 2028-06-02"
  end

  test "photos stored sideways or upside down are turned upright from their EXIF orientation" do
    upright = ScannedPdf.text_image(CHEN, page_points: CARD)
    { 6 => upright.rot(:d270), 3 => upright.rot(:d180), 8 => upright.rot(:d90) }.each do |orientation, stored|
      path = file("oriented-#{orientation}.jpg")
      stored = stored.copy
      stored.set_type(GObject::GINT_TYPE, "orientation", orientation)
      stored.jpegsave(path, Q: 90)

      assert_includes extract(path, "image/jpeg").text, "Awarded to: Li Chen", "EXIF orientation #{orientation}"
    end
  end

  test "a photo with transparency is flattened onto white" do
    ink = ScannedPdf.text_image(ORTIZ)
    alpha = (ink * -1 + 255).cast(:uchar) # opaque where the text is, transparent elsewhere
    Vips::Image.black(ink.width, ink.height).bandjoin(alpha).copy(interpretation: :b_w).pngsave(file("clear.png"))

    assert_includes extract(file("clear.png"), "image/png").text, "Juan A. Ortiz"
  end

  test "a reading tesseract is unsure of is dropped, so the page goes to the vision model" do
    ScannedPdf.text_image(ORTIZ, page_points: CARD).fliphor.write_to_file(file("mirrored.png")) # a selfie-camera photo

    page = extract(file("mirrored.png"), "image/png").pages.sole

    assert page.ocr
    assert_equal "", page.text
    assert_not Imports::TextExtractor.usable?(page.text)
  end

  test "a blank scan yields an empty page, not noise" do
    path = ScannedPdf.write(file("blank.pdf"), [ Vips::Image.black(850, 1100).invert.copy(interpretation: :b_w) ])

    page = extract(path, "application/pdf").pages.sole

    assert_equal "", page.text
    assert_not Imports::TextExtractor.usable?(page.text)
  end

  test "the content type is sniffed when the declared one is missing or generic" do
    path = ScannedPdf.write_text_pdf(file("upload.bin"), [ ORTIZ ])

    assert_includes extract(path, "application/octet-stream").text, "Juan A. Ortiz"
    assert_includes extract(path, nil).text, "Juan A. Ortiz"
    assert_includes extract(path, "Application/PDF; charset=binary").text, "Juan A. Ortiz"
  end

  test "unsupported files are refused" do
    File.write(file("notes.txt"), "CERTIFICATE OF COMPLETION\nAwarded to: Juan A. Ortiz\n")

    error = assert_raises(Imports::TextExtractor::UnsupportedType) { extract(file("notes.txt"), "text/plain") }
    assert_match "text/plain is not a supported file type", error.message
  end

  test "a file labelled as an image is only opened by the JPEG, PNG, WebP and HEIF loaders" do
    ScannedPdf.text_image(ORTIZ).write_to_file(file("scan.tif"))
    FileUtils.mv(file("scan.tif"), file("scan.png"))

    error = assert_raises(Imports::TextExtractor::UnsupportedType) { extract(file("scan.png"), "image/png") }
    assert_match "tiffload is not a supported image format", error.message

    File.write(file("logo.png"), %(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>))
    assert_raises(Imports::TextExtractor::Error) { extract(file("logo.png"), "image/png") }
  end

  test "a corrupt PDF or image raises a readable error" do
    File.write(file("broken.pdf"), "%PDF-1.4\nthis is not really a pdf")
    File.binwrite(file("broken.jpg"), "\xFF\xD8\xFF\xE0garbage".b)

    error = assert_raises(Imports::TextExtractor::Error) { extract(file("broken.pdf"), "application/pdf") }
    assert_match "could not be read as a PDF", error.message
    error = assert_raises(Imports::TextExtractor::Error) { extract(file("broken.jpg"), "image/jpeg") }
    assert_match "The image could not be read", error.message
    assert_not_includes error.message, @dir, "no server paths in messages users see"
  end

  test "a tool that hangs past the timeout raises Shell::TimedOut" do
    path = ScannedPdf.write(file("scan.pdf"), [ ORTIZ ])

    assert_raises(Imports::Shell::TimedOut) do
      Imports::TextExtractor.new(path, content_type: "application/pdf", timeout: 0.001).call
    end
  end

  test "temp files are cleaned up" do
    path = ScannedPdf.write(file("scan.pdf"), [ ScannedPdf.text_image(ORTIZ, page_points: CARD) ])

    # Only this process's folders (Dir.mktmpdir names hold the pid): parallel workers share /tmp.
    assert_no_difference -> { Dir.glob(File.join(Dir.tmpdir, "certtrack-text*-#{Process.pid}-*")).size } do
      extract(path, "application/pdf")
    end
  end

  test "usable? wants enough letters and digits, mostly text, and real words" do
    assert Imports::TextExtractor.usable?(ORTIZ)
    assert Imports::TextExtractor.usable?(OUTLINE)
    assert Imports::TextExtractor.usable?("#{ORTIZ}\nSignature: ______________________________ Date: __________")

    assert_not Imports::TextExtractor.usable?(nil)
    assert_not Imports::TextExtractor.usable?("   \n ")
    assert_not Imports::TextExtractor.usable?("Page 1 of 2"), "too short"
    assert_not Imports::TextExtractor.usable?("CERTIFICATE OF COMPLETION Juan Ortiz"), "under ocr_min_chars"
    assert_not Imports::TextExtractor.usable?("|~ \\/ ;: '' {} =| _- ~~ " * 10 + "abc def ghi jkl mno pqr"), "mostly symbols"
    assert_not Imports::TextExtractor.usable?("2025-03-14 30-1234567 2028-03-14 99-7654321 12345"), "no words"
  end

  test "usable? follows Imports::Config.ocr_min_chars" do
    Imports::Config.with(ocr_min_chars: 5) { assert Imports::TextExtractor.usable?("Flagger card Li Chen") }
    Imports::Config.with(ocr_min_chars: 500) { assert_not Imports::TextExtractor.usable?(ORTIZ) }
  end

  test "split_pages parses stored text back into pages" do
    stored = "=== page 1 ===\nCERTIFICATE OF COMPLETION\nAwarded to: Li Chen\n\n=== page 2 ===\n\n\n=== page 3 ===\nCOURSE OUTLINE"

    pages = Imports::TextExtractor.split_pages(stored)

    assert_equal [ 1, 2, 3 ], pages.map(&:number)
    assert_equal [ "CERTIFICATE OF COMPLETION\nAwarded to: Li Chen", "", "COURSE OUTLINE" ], pages.map(&:text)
    assert_equal [ nil, nil, nil ], pages.map(&:ocr)
    assert_equal [], Imports::TextExtractor.split_pages(nil)
    assert_equal [ [ 1, "Loose text" ] ], Imports::TextExtractor.split_pages("Loose text\n").map { |page| [ page.number, page.text ] }
  end

  test "page text that looks like a page marker can't split a page" do
    path = ScannedPdf.write_text_pdf(file("tricky.pdf"), [ "#{ORTIZ}\n=== page 9 ===\nmore text after it" ])

    result = extract(path, "application/pdf")

    assert_equal [ 1 ], Imports::TextExtractor.split_pages(result.text).map(&:number)
    assert_includes result.text, "== page 9 =="
  end

  test "render_dpi keeps an oversized page within the pixel limit" do
    assert_equal 300, Imports::TextExtractor.render_dpi(792)
    assert_equal 300, Imports::TextExtractor.render_dpi(nil)
    dpi = Imports::TextExtractor.render_dpi(14_400) # a 200-inch page
    assert_operator dpi * 14_400 / 72.0, :<=, Imports::TextExtractor::MAX_RENDER_SIDE
  end

  test "page_count reads the PDF's page count" do
    path = ScannedPdf.write_text_pdf(file("three.pdf"), [ ORTIZ, CHEN, OUTLINE ])

    assert_equal 3, Imports::TextExtractor.page_count(path)
  end

  private
    def file(name)
      File.join(@dir, name)
    end

    def extract(path, content_type)
      Imports::TextExtractor.new(path, content_type: content_type).call
    end

    def skip_unless_heif
      skip "libvips #{Vips.version_string} has no HEIF loader" if Vips.type_find("VipsOperation", "heifload").zero?
    end
end
