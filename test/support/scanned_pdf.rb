require "cgi"
require "vips"
require "combine_pdf"

# Builds synthetic certificate files with the real tools, so text extraction and OCR
# are exercised end to end in tests. Every name, number and issuer is made up.
#
#   text = ScannedPdf.certificate_text(holder: "Juan A. Ortiz")
#   ScannedPdf.write(path, [ text ])               # image-only PDF: no text layer, OCR needed
#   ScannedPdf.write_text_pdf(path, [ text ])      # real text layer (combine_pdf)
#   ScannedPdf.text_image(text).write_to_file(path) # .png / .jpg / .webp / .heic
#
# The image-only PDF is hand-built: each page draws one full-page grayscale JPEG
# through /DCTDecode, which is what a scanner or phone "scan to PDF" app produces.
module ScannedPdf
  DPI = 300
  LETTER_POINTS = [ 612, 792 ].freeze
  MARGIN_POINTS = 54

  module_function

  # The SYNTHETIC CERTIFICATE TEXT format Ai::FakeProvider parses: one certificate.
  def certificate_text(name: "OSHA 30-Hour Construction Industry Outreach Training", holder: "Juan A. Ortiz",
    number: "30-1234567", completed: "2025-03-14", expires: nil, issuer: "Example Safety Training LLC")
    [
      "CERTIFICATE OF COMPLETION", name, "Awarded to: #{holder}", "Certificate No: #{number}",
      "Completed: #{completed}", ("Expires: #{expires}" if expires), "Issued by: #{issuer}"
    ].compact.join("\n")
  end

  # Black text on a white page-sized (letter by default) one-band image, like a clean scan.
  # text is plain text (escaped here, since libvips reads Pango markup). A page too short
  # for the text grows to fit it.
  def text_image(text, dpi: DPI, page_points: LETTER_POINTS, font: "sans 12")
    width, height = page_points.map { |points| (points * dpi / 72.0).round }
    margin = (MARGIN_POINTS * dpi / 72.0).round
    ink = Vips::Image.text(CGI.escapeHTML(text), dpi: dpi, font: font, width: width - 2 * margin)
    height = [ height, ink.height + 2 * margin ].max
    page = (ink * -1 + 255).cast(:uchar).embed(margin, margin, width, height, extend: :white)
    page.copy(interpretation: :b_w)
  end

  def jpeg_bytes(image, quality: 85)
    image.jpegsave_buffer(Q: quality, strip: true)
  end

  # Writes an image-only PDF with one scanned page per entry. An entry is certificate
  # (or any) text to render, or a ready Vips::Image. Returns path.
  def write(path, pages, dpi: DPI)
    images = Array(pages).map { |page| page.is_a?(Vips::Image) ? page : text_image(page, dpi: dpi) }
    File.binwrite(path, image_pdf(images.map { |image| [ image, jpeg_bytes(image.colourspace(:b_w)) ] }, dpi: dpi))
    path
  end

  # Writes a PDF with a real text layer, one page per text (one textbox per line).
  def write_text_pdf(path, pages)
    pdf = CombinePDF.new
    Array(pages).each do |text|
      page = pdf.new_page
      text.lines.map(&:chomp).each_with_index do |line, index|
        page.textbox(line, x: 72, y: 700 - index * 24, width: 470, height: 20, font_size: 12, max_font_size: 12,
          text_align: :left)
      end
    end
    pdf.save(path)
    path
  end

  # Concatenates PDFs (page order kept) into path with combine_pdf. Returns path.
  def combine(path, *sources)
    pdf = CombinePDF.new
    sources.each { |source| pdf << CombinePDF.load(source) }
    pdf.save(path)
    path
  end

  # Minimal PDF 1.4: catalog, page tree, then per page a content stream and an image XObject.
  def image_pdf(images, dpi:)
    count = images.size
    objects = []
    objects << "<< /Type /Catalog /Pages 2 0 R >>"
    kids = (0...count).map { |index| "#{3 + index * 3} 0 R" }.join(" ")
    objects << "<< /Type /Pages /Kids [#{kids}] /Count #{count} >>"

    images.each_with_index do |(image, jpeg), index|
      page_id = 3 + index * 3
      width = (image.width * 72.0 / dpi).round(2)
      height = (image.height * 72.0 / dpi).round(2)
      content = "q #{width} 0 0 #{height} 0 0 cm /Im0 Do Q\n"
      objects << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{width} #{height}] " \
                 "/Resources << /XObject << /Im0 #{page_id + 2} 0 R >> >> /Contents #{page_id + 1} 0 R >>"
      objects << "<< /Length #{content.bytesize} >>\nstream\n#{content}endstream"
      objects << "<< /Type /XObject /Subtype /Image /Width #{image.width} /Height #{image.height} " \
                 "/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode /Length #{jpeg.bytesize} >>\n" \
                 "stream\n#{jpeg.b}\nendstream"
    end

    serialize(objects)
  end

  def serialize(objects)
    pdf = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".b
    offsets = objects.each_with_index.map do |body, index|
      offset = pdf.bytesize
      pdf << "#{index + 1} 0 obj\n".b << body.b << "\nendobj\n".b
      offset
    end
    xref = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n".b
    offsets.each { |offset| pdf << format("%010d 00000 n \n", offset).b }
    pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n".b
  end
end
