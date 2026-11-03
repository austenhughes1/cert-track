require "combine_pdf"

# Builders for the matching, review and ProcessExtractionJob tests: synthetic certificate
# PDFs (combine_pdf text boxes, one certificate per page), model-contract certificate
# hashes and import items with a file attached. Every name and number is made up.
module ImportsMatchTestSupport
  # The SYNTHETIC CERTIFICATE TEXT format, as lines.
  def certificate_lines(name:, holder:, number: "C-0001", completed: "2025-03-14", expires: nil, issuer: "Example Safety Training LLC")
    [ "CERTIFICATE OF COMPLETION", name, "Awarded to: #{holder}", "Certificate No: #{number}",
      "Completed: #{completed}", ("Expires: #{expires}" if expires), "Issued by: #{issuer}" ].compact
  end

  # PDF bytes, one page per entry of pages (each an Array of lines).
  def synthetic_pdf(pages)
    pdf = CombinePDF.new
    pages.each do |lines|
      page = pdf.new_page([ 0, 0, 612, 792 ])
      Array(lines).each_with_index do |line, index|
        page.textbox(line, x: 36, y: 720 - (index * 24), width: 540, height: 20, font_size: 12, text_align: :left)
      end
    end
    pdf.to_pdf
  end

  # Text as Imports::TextExtractor stores it.
  def marked_text(pages)
    pages.each_with_index.map { |lines, index| "=== page #{index + 1} ===\n#{Array(lines).join("\n")}" }.join("\n")
  end

  # A certificate entry from the model output contract (string keys).
  def certificate_entry(pages: [ 1 ], holder: "Juan A. Ortiz", code: "OSHA30",
    name: "OSHA 30-Hour Construction Industry Outreach Training", number: "30-1234567",
    completed: (Date.current - 30).iso8601, expires: nil, confidence: 0.95, issuer: "Example Safety Training LLC")
    { "pages" => pages, "holder_name" => holder, "certificate_type_code" => code,
      "certificate_name_as_printed" => name, "issuer" => issuer, "certificate_number" => number,
      "completed_on" => completed, "expires_on" => expires, "confidence" => confidence, "notes" => nil }
  end

  def extraction_with(*certificates, non_certificate_pages: [])
    { "certificates" => certificates, "non_certificate_pages" => non_certificate_pages }
  end

  def import_batch
    @import_batch ||= ImportBatch.create!(uploaded_by: users(:manager), status: :processing)
  end

  # An item as Imports::AiExtractJob leaves it: extracting, with its file and extraction.
  def pipeline_item(bytes:, filename:, content_type:, extraction: nil, extracted_text: nil, batch: import_batch, **attrs)
    ImportItem.create!({ import_batch: batch, status: :extracting, original_filename: filename,
      sha256: Digest::SHA256.hexdigest(bytes), extraction:, extracted_text:, provider: "fake", ai_units_used: 12,
      file: { io: StringIO.new(bytes), filename: File.basename(filename), content_type: content_type } }.merge(attrs))
  end

  # bytes: reuse a PDF to get the same sha256 (synthetic_pdf stamps the creation time).
  def pdf_item(pages, extraction:, filename: "crew.zip/cards/ortiz.pdf", bytes: synthetic_pdf(pages), **attrs)
    pipeline_item(bytes:, filename:, content_type: "application/pdf",
      extraction:, extracted_text: marked_text(pages), **attrs)
  end

  def image_item(extraction:, filename: "IMG_0042.jpg", **attrs)
    bytes = file_fixture("certificate.jpg").binread
    pipeline_item(bytes:, filename:, content_type: "image/jpeg", extraction:, **attrs)
  end

  # An item waiting in the review queue with proposals filled in.
  def review_item(member: crew_members(:juan_ortiz), type: certificate_types(:osha30), **attrs)
    bytes = attrs.delete(:bytes) || "review-#{SecureRandom.hex(8)}"
    ImportItem.create!({ import_batch: import_batch, status: :needs_review, original_filename: "front.jpg",
      sha256: Digest::SHA256.hexdigest(bytes), holder_name_raw: member&.full_name, certificate_name_raw: type&.name,
      issuer_raw: "Example Safety Training LLC", matched_crew_member: member, person_match: (member ? :matched : :unmatched),
      matched_certificate_type: type, type_match: (type ? :matched : :unmatched), confidence: 0.9,
      proposed_completed_on: Date.current - 30, proposed_certificate_number: "30-9990001",
      file: { io: StringIO.new(file_fixture("certificate.jpg").binread), filename: "front.jpg", content_type: "image/jpeg" } }.merge(attrs))
  end

  def pdf_page_count(blob)
    CombinePDF.parse(blob.download).pages.size
  end

  # Text of a stored PDF (poppler), squished.
  def pdf_text(blob)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "file.pdf")
      File.binwrite(path, blob.download)
      Imports::Shell.run("pdftotext", "-layout", path, "-").squish
    end
  end

  def with_auto_accept(enabled = true, &block)
    Imports::Config.with(auto_accept_enabled: enabled, &block)
  end
end
