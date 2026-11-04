require "test_helper"
require_relative "../../support/scanned_pdf"

class Certificates::PdfShrinkerTest < ActiveSupport::TestCase
  CARD_POINTS = [ 432, 288 ].freeze # a 6 x 4 inch card keeps the test scans small
  TEXT_LAYER = "Certificate No: 30-1234567".freeze

  setup do
    @dir = Dir.mktmpdir("pdf-shrinker-test-")
  end

  teardown do
    FileUtils.rm_rf(@dir)
  end

  test "a 300 ppi colour scan is re-encoded at 200 ppi with its text layer and metadata kept" do
    source = scan_pdf(color: true, catalog: "/Lang (en-US) /MarkInfo << /Marked true >>",
      info: "<< /Producer (Example Scanner) /CreationDate (D:20250314120000Z) >>")

    assert_equal output, shrink(source)

    image = images(output).sole
    assert_equal [ 200, 200, "rgb", 1200 ], [ image[:xppi], image[:yppi], image[:color], image[:width] ]
    assert_operator File.size(output), :<, File.size(source) * 0.6
    assert_includes tool("pdftotext", output, "-"), TEXT_LAYER
    info = tool("pdfinfo", output)
    assert_match(/^Pages:\s+1$/, info)
    assert_match(/^Tagged:\s+yes$/, info)
    assert_match(/^Producer:\s+Example Scanner$/, info)
  end

  test "every big page of a gray multi-page scan shrinks" do
    pages = 3.times.map { |index| ScannedPdf.text_image(ScannedPdf.certificate_text(number: "30-00#{index}"), page_points: CARD_POINTS) }
    source = ScannedPdf.write(File.join(@dir, "scan.pdf"), pages)

    assert_equal output, shrink(source)

    assert_equal [ [ 200, "gray" ] ] * 3, images(output).map { |image| [ image[:xppi], image[:color] ] }
    assert_equal tool("pdftotext", source, "-"), tool("pdftotext", output, "-")
  end

  test "an ICC-tagged RGB scan keeps its colour space" do
    source = scan_pdf(color: true, color_space: "[/ICCBased 6 0 R]", extra: [ icc_profile_object ])

    assert_equal output, shrink(source)
    assert_equal "icc", images(output).sole[:color]
  end

  test "a PDF made on a computer is left alone" do
    source = ScannedPdf.write_text_pdf(File.join(@dir, "typed.pdf"), [ ScannedPdf.certificate_text ])

    assert_nil shrink(source)
    assert_not File.exist?(output)
  end

  test "a scan already at 220 ppi or less is left alone" do
    assert_nil shrink(scan_pdf(dpi: 220))
  end

  test "a result that isn't small enough is thrown away" do
    source = scan_pdf

    assert_nil shrink(source, under: File.size(source) * 0.1)
  end

  test "unusual PDFs are left alone" do
    {
      "encrypted" => scan_pdf(trailer: "/Encrypt 6 0 R", extra: [ "<< /Filter /Standard /V 1 /R 2 /O (#{"x" * 32}) /U (#{"y" * 32}) /P -4 >>" ]),
      "signed" => scan_pdf(catalog: "/AcroForm << /Fields [6 0 R] /SigFlags 3 >>",
        extra: [ "<< /FT /Sig /T (Signature1) /V 7 0 R >>", "<< /Type /Sig /ByteRange [0 10 20 30] /Contents <00> >>" ]),
      "with a signature and no form" => scan_pdf(extra: [ "<< /Type /Sig /ByteRange [0 10 20 30] /Contents <00> >>" ]),
      "with a form" => scan_pdf(catalog: "/AcroForm << /Fields [] >>"),
      "with attached files" => scan_pdf(catalog: "/Names << /EmbeddedFiles << /Names [] >> >>"),
      "with a script to run" => scan_pdf(catalog: "/OpenAction << /S /JavaScript /JS (app.alert(1)) >>")
    }.each do |kind, source|
      assert_nil shrink(source), kind
    end
  end

  test "an encrypted PDF is left alone even when poppler can open it" do
    source = scan_pdf(trailer: "/Encrypt 6 0 R", extra: [ "<< /Filter /Standard /V 1 /R 2 /O (#{"x" * 32}) /U (#{"y" * 32}) /P -4 >>" ])
    readable = shrinker(source)
    readable.define_singleton_method(:big_jpegs) { { [ 5, 0 ] => 300 } } # as pdfimages lists a PDF with only an owner password

    assert_nil readable.call
  end

  test "images that can't be re-encoded safely are left alone" do
    page = ScannedPdf.text_image(ScannedPdf.certificate_text, page_points: CARD_POINTS)
    cmyk = page.colourspace(:srgb).icc_transform("cmyk", input_profile: "srgb")
    mask = ScannedPdf.jpeg_bytes(page)

    {
      "CMYK" => scan_pdf(image: cmyk, color_space: "/DeviceCMYK"),
      "soft mask" => scan_pdf(image_entries: "/SMask 6 0 R", extra: [ image_object(page, mask, "/DeviceGray") ]),
      "Decode array" => scan_pdf(image_entries: "/Decode [1 0]"),
      "Flate (lossless)" => scan_pdf(filter: "/FlateDecode", data: Zlib::Deflate.deflate(page.write_to_memory)),
      "16-bit" => scan_pdf(bits: 16)
    }.each do |kind, source|
      assert_nil shrink(source), kind
    end
  end

  test "a result poppler disagrees with is thrown away" do
    source = scan_pdf
    changed_text = shrinker(source)
    changed_text.define_singleton_method(:text) { |path| path == output ? "something else" : super(path) }
    changed_look = shrinker(source)
    changed_look.define_singleton_method(:similar?) { |*| false }

    assert_nil changed_text.call
    assert_nil changed_look.call
  end

  test "a PDF combine_pdf or poppler can't read is left alone" do
    source = File.join(@dir, "broken.pdf")
    File.binwrite(source, "%PDF-1.4\nnot really a PDF\n")

    assert_nil shrink(source)
  end

  private
    def output
      File.join(@dir, "out.pdf")
    end

    def shrinker(source, under: File.size(source) * 0.8)
      Certificates::PdfShrinker.new(source, output, under: under)
    end

    def shrink(source, **options)
      shrinker(source, **options).call
    end

    def tool(*argv)
      Imports::Shell.run(*argv)
    end

    # The images pdfimages -list reports (columns: page num type width height color comp bpc
    # enc interp object-number generation x-ppi y-ppi size ratio).
    def images(path)
      tool("pdfimages", "-list", path).lines.map(&:split).select { |columns| columns.first&.match?(/\A\d+\z/) }.map do |columns|
        { width: columns[3].to_i, color: columns[5], xppi: columns[12].to_i, yppi: columns[13].to_i }
      end
    end

    # A one-page scanned card: a JPEG drawn at dpi under an invisible text layer (what a
    # scanner's "searchable PDF" makes). Objects 1-5 are fixed; extra ones start at 6.
    def scan_pdf(dpi: 300, color: false, image: nil, color_space: nil, bits: 8, filter: "/DCTDecode", data: nil,
      image_entries: "", catalog: "", info: nil, trailer: "", extra: [])
      image ||= ScannedPdf.text_image(ScannedPdf.certificate_text, dpi: dpi, page_points: CARD_POINTS)
      image = image.colourspace(:srgb) if color
      color_space ||= image.bands == 1 ? "/DeviceGray" : "/DeviceRGB"
      data ||= ScannedPdf.jpeg_bytes(image)
      width, height = CARD_POINTS
      content = "q #{width} 0 0 #{height} 0 0 cm /Im0 Do Q\nBT 3 Tr /F1 12 Tf 36 36 Td (#{TEXT_LAYER}) Tj ET\n"
      objects = [
        "<< /Type /Catalog /Pages 2 0 R #{catalog} >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{width} #{height}] " \
          "/Resources << /XObject << /Im0 5 0 R >> /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> " \
          "/Contents 4 0 R >>",
        "<< /Length #{content.bytesize} >>\nstream\n#{content}endstream",
        image_object(image, data, color_space, bits: bits, filter: filter, entries: image_entries),
        *extra
      ]
      objects << info if info
      pdf = ScannedPdf.serialize(objects)
      pdf.sub!("/Root 1 0 R", "/Root 1 0 R /Info #{objects.size} 0 R") if info
      pdf.sub!("/Root 1 0 R", "/Root 1 0 R #{trailer}")
      File.join(@dir, "scan-#{SecureRandom.hex(4)}.pdf").tap { |path| File.binwrite(path, pdf) }
    end

    def image_object(image, data, color_space, bits: 8, filter: "/DCTDecode", entries: "")
      "<< /Type /XObject /Subtype /Image /Width #{image.width} /Height #{image.height} /ColorSpace #{color_space} " \
        "/BitsPerComponent #{bits} /Filter #{filter} #{entries} /Length #{data.bytesize} >>\nstream\n#{data.b}\nendstream".b
    end

    # libvips' built-in sRGB profile as an ICCBased stream.
    def icc_profile_object
      profile = Vips::Image.black(1, 1, bands: 3).copy(interpretation: :srgb).icc_transform("srgb", input_profile: "srgb")
        .get("icc-profile-data")
      "<< /N 3 /Length #{profile.bytesize} >>\nstream\n#{profile.b}\nendstream".b
    end
end
