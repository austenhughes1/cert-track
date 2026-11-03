require "zip"
require "stringio"
require "securerandom"
require "cgi"
require "combine_pdf"
require "vips"
require_relative "scanned_pdf"

# SYNTHETIC import files for tests and dev demos: certificates in the SYNTHETIC
# CERTIFICATE TEXT format that Ai::FakeProvider parses, rendered as text PDFs,
# image-only (scanned) PDFs, photos and zips. Every name, number and issuer is made up.
# Real samples belong in test/fixtures/import_samples/ (gitignored), never here.
#
#   require "support/import_samples"
#
#   ImportSamples.certificate_text(holder: "Li Chen")             # one page of text
#   ImportSamples.pdf({}, { holder: "Li Chen" }, :outline)        # 3-page text PDF (bytes)
#   ImportSamples.scanned_pdf({}, :outline)                       # image-only PDF, needs OCR
#   ImportSamples.image({ holder: "Li Chen" }, format: :heic)     # :jpeg, :png, :webp, :heic (braces needed)
#   ImportSamples.zip("cards/a.pdf" => pdf_bytes, "../evil.pdf" => pdf_bytes, "/abs.pdf" => ...)
#   ImportSamples.nested_zip(2, "card.pdf" => pdf_bytes)          # a zip in a zip in a zip
#   ImportSamples.zip_slip                                        # cards/ok.pdf + ../evil.pdf
#   ImportSamples.declare_size(zip, "bomb.pdf", 100)              # header lies about the size
#   ImportSamples.combine(pdf, scanned_pdf)                       # pages of both, in order
#   ImportSamples.write(dir, "crew/a.pdf", bytes)                 # => Pathname
#   ImportSamples.blob(bytes, filename: "crew.zip")               # uploaded ActiveStorage::Blob
#   ImportSamples.batch(users(:manager), "crew.zip" => zip_bytes) # receiving batch with uploads
#
# A page is a Hash of certificate fields (see CERTIFICATE; {} is the default card),
# :outline for a non-certificate page, or a String of raw page text. Everything returns
# binary Strings. HEIC needs libheif with an encoder: check ImportSamples.heic_supported?.
module ImportSamples
  CERTIFICATE = {
    name: "OSHA 30-Hour Construction Industry Outreach Training",
    holder: "Juan A. Ortiz",
    number: "30-1234567",
    completed: "2025-03-14",
    expires: nil,
    issuer: "Example Safety Training LLC"
  }.freeze

  # A course outline: no "CERTIFICATE" line, so it is a non-certificate page.
  OUTLINE_TEXT = <<~TEXT.chomp.freeze
    COURSE OUTLINE
    Module 1: Hazard recognition and site walkthrough
    Module 2: Fall protection systems and anchor points
    Module 3: Electrical safety near overhead lines
    Module 4: Personal protective equipment
    Instructor notes and attendance sign-in sheet
  TEXT

  CONTENT_TYPES = {
    ".pdf" => "application/pdf", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".png" => "image/png",
    ".webp" => "image/webp", ".heic" => "image/heic", ".heif" => "image/heif", ".zip" => "application/zip",
    ".txt" => "text/plain"
  }.freeze

  IMAGE_FORMATS = { jpeg: ".jpg", jpg: ".jpg", png: ".png", webp: ".webp", heic: ".heic" }.freeze

  module_function

  # --- Text ---------------------------------------------------------------------------

  # The fields of one synthetic certificate: CERTIFICATE with overrides.
  def certificate(**overrides)
    unknown = overrides.keys - CERTIFICATE.keys
    raise ArgumentError, "unknown certificate fields: #{unknown.join(", ")}" if unknown.any?

    CERTIFICATE.merge(overrides)
  end

  # One page of SYNTHETIC CERTIFICATE TEXT (the Expires line only when expires is set).
  def certificate_text(**overrides)
    ScannedPdf.certificate_text(**certificate(**overrides))
  end

  def outline_text
    OUTLINE_TEXT
  end

  # The text of a page spec: a Hash of certificate fields, :outline, or a String.
  def page_text(page)
    case page
    when Hash then certificate_text(**page)
    when :outline then OUTLINE_TEXT
    when String then page
    else raise ArgumentError, "a page is a Hash of certificate fields, :outline or a String, not #{page.inspect}"
    end
  end

  # --- PDFs and images (all return bytes) ----------------------------------------------

  # A PDF with a real text layer (pdftotext reads it), one page per page spec.
  # pdf() with no pages is one default certificate. The bytes differ on every call
  # (combine_pdf stamps the time and random font names): to make a duplicate, reuse them.
  def pdf(*pages)
    pages = [ {} ] if pages.empty?
    document = CombinePDF.new
    pages.flatten.each do |page|
      sheet = document.new_page([ 0, 0, 612, 792 ])
      page_text(page).lines.map(&:chomp).each_with_index do |line, index|
        sheet.textbox(line, x: 72, y: 700 - index * 24, width: 470, height: 20, font_size: 12, max_font_size: 12,
          text_align: :left)
      end
    end
    document.to_pdf.b
  end

  # An image-only PDF (no text layer, like a scanner's output): pdftotext finds nothing and
  # OCR is needed. Each page is a letter-size 300 dpi scan, so OCR is slow-ish (~1 s a page).
  def scanned_pdf(*pages, dpi: ScannedPdf::DPI)
    pages = [ {} ] if pages.empty?
    images = pages.flatten.map do |page|
      image = ScannedPdf.text_image(page_text(page), dpi: dpi)
      [ image, ScannedPdf.jpeg_bytes(image.colourspace(:b_w)) ]
    end
    ScannedPdf.image_pdf(images, dpi: dpi).b
  end

  # Page order kept: combine(pdf({}), scanned_pdf(:outline)) is a text page then a scan.
  def combine(*pdfs)
    document = CombinePDF.new
    pdfs.each { |bytes| document << CombinePDF.parse(bytes) }
    document.to_pdf.b
  end

  # A photo of one page: black text on white at 300 dpi, large enough for tesseract.
  # format: :jpeg, :png, :webp or :heic. orientation: an EXIF orientation (JPEG only, e.g. 6
  # = "rotate 90° clockwise to view"): the pixels are stored turned so autorot puts them upright.
  def image(page = {}, format: :jpeg, orientation: nil, dpi: 300)
    extension = IMAGE_FORMATS.fetch(format.to_sym) { raise ArgumentError, "unknown image format #{format.inspect}" }
    ink = Vips::Image.text(CGI.escapeHTML(page_text(page)), dpi: dpi, font: "sans 12", width: (7 * dpi).round)
    margin = (dpi / 2.0).round
    picture = (ink * -1 + 255).cast(:uchar).embed(margin, margin, ink.width + 2 * margin, ink.height + 2 * margin,
      extend: :white)

    if orientation
      raise ArgumentError, "orientation is only written for JPEG" unless extension == ".jpg"

      picture = stored_for_orientation(picture, orientation)
    end

    case extension
    when ".heic" then picture.colourspace(:srgb).heifsave_buffer(compression: :hevc, Q: 90)
    when ".jpg" then picture.jpegsave_buffer(Q: 90)
    else picture.write_to_buffer(extension)
    end
  end

  # True when this libvips can write HEIC (libheif with an HEVC encoder).
  def heic_supported?
    return @heic_supported if defined?(@heic_supported)

    @heic_supported = begin
      Vips::Image.black(8, 8).colourspace(:srgb).heifsave_buffer(compression: :hevc).bytesize.positive?
    rescue Vips::Error, NoMethodError
      false
    end
  end

  # --- Zips ----------------------------------------------------------------------------

  # A zip of name => bytes (a Hash, or an Array of pairs to repeat names). Names are written
  # verbatim, so hostile ones work: "../evil.pdf", "/abs/evil.pdf", "C:/evil.pdf",
  # "__MACOSX/._a.pdf". A name ending in "/" is a directory entry (bytes ignored).
  # compression: :deflate (default) or :store, positional (zip(entries, :store)) so a
  # braceless hash of names stays the entries.
  def zip(entries, compression = :deflate)
    placeholders = {}
    buffer = without_zip64 do
      Zip::OutputStream.write_buffer(StringIO.new(+"".b)) do |stream|
        entries.each do |name, bytes|
          written = name
          if name.start_with?("/") # rubyzip refuses these: write a same-length stand-in, patched below
            written = "x#{SecureRandom.alphanumeric(name.bytesize - 1)}"
            placeholders[written] = name
          end
          method = compression == :store ? Zip::Entry::STORED : Zip::Entry::DEFLATED
          stream.put_next_entry(written, "", Zip::ExtraField.new, method)
          stream.write(bytes.to_s) unless name.end_with?("/")
        end
      end
    end

    placeholders.reduce(buffer.string.b) { |zip, (stand_in, name)| zip.gsub(stand_in.b, name.b) }
  end

  # levels zips nested inside each other around entries: nested_zip(0, x) is zip(x),
  # nested_zip(2, x) is outer.zip > level1.zip > level2.zip > entries. Inner zips are named
  # "level1.zip", "level2.zip"... (a third argument changes "level").
  def nested_zip(levels, entries, prefix = "level")
    levels.downto(1).reduce(zip(entries)) { |inner, level| zip("#{prefix}#{level}.zip" => inner) }
  end

  # The classic zip-slip archive: one safe card and one entry that climbs out of the folder.
  def zip_slip(evil_name = "../evil.pdf")
    zip("cards/ok.pdf" => pdf({}), evil_name => pdf({ holder: "Evil Example" }))
  end

  # Rewrites the uncompressed size that the local and central headers declare for name
  # (both headers), so the archive lies about how big the entry is. Build the zip with
  # zip(), which writes plain 32-bit sizes.
  def declare_size(zip_bytes, name, declared)
    bytes = zip_bytes.b
    patched = 0
    { "PK\x03\x04".b => [ 26, 30, 22 ], "PK\x01\x02".b => [ 28, 46, 24 ] }.each do |signature, (name_length_at, name_at, size_at)|
      offset = 0
      while (offset = bytes.index(signature, offset))
        length = bytes[offset + name_length_at, 2].unpack1("v")
        if bytes[offset + name_at, length] == name.b
          bytes[offset + size_at, 4] = [ declared ].pack("V")
          patched += 1
        end
        offset += 4
      end
    end
    raise ArgumentError, "#{name} is not in the zip" if patched.zero?

    bytes
  end

  # Names of the entries in a zip, as stored.
  # (open_buffer's block form returns the buffer, not the block's value.)
  def entry_names(zip_bytes)
    Zip::File.open_buffer(StringIO.new(zip_bytes)).entries.map(&:name)
  end

  # --- Files, blobs, batches -------------------------------------------------------------

  # Writes bytes to dir/name (creating folders) and returns the Pathname.
  def write(dir, name, bytes)
    path = Pathname(dir).join(name)
    path.dirname.mkpath
    path.binwrite(bytes)
    path
  end

  def content_type_for(filename)
    CONTENT_TYPES.fetch(File.extname(filename.to_s).downcase, "application/octet-stream")
  end

  # An uploaded blob, like a finished direct upload.
  def blob(bytes, filename:, content_type: content_type_for(filename))
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: filename, content_type: content_type,
      identify: false)
  end

  # A receiving ImportBatch by user with each filename => bytes attached as an upload,
  # as ImportsController#create leaves it before ExpandJob runs.
  def batch(user, files)
    ImportBatch.create!(uploaded_by: user, status: :receiving,
      uploads: files.map { |filename, bytes| blob(bytes, filename: filename) })
  end

  # --- private helpers -------------------------------------------------------------------

  def without_zip64
    previous = Zip.write_zip64_support
    Zip.write_zip64_support = false
    yield
  ensure
    Zip.write_zip64_support = previous
  end

  # The pixels a camera stores for an EXIF orientation, plus the tag (JPEG keeps it).
  def stored_for_orientation(upright, orientation)
    stored = case orientation.to_i
    when 1 then upright
    when 3 then upright.rot(:d180)
    when 6 then upright.rot(:d270)
    when 8 then upright.rot(:d90)
    else raise ArgumentError, "orientation must be 1, 3, 6 or 8"
    end
    stored.mutate { |image| image.set_type!(GObject::GINT_TYPE, "orientation", orientation.to_i) }
  end
end
