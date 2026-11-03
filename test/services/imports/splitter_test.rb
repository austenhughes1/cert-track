require "test_helper"
require_relative "match_test_support"

class Imports::SplitterTest < ActiveSupport::TestCase
  include ImportsMatchTestSupport

  PAGES = [
    [ "CERTIFICATE OF COMPLETION", "OSHA 30 Hour", "Awarded to: Juan A. Ortiz" ],
    [ "COURSE OUTLINE", "Module 1: Fall protection" ],
    [ "CERTIFICATE OF COMPLETION", "Flagger Certification", "Awarded to: Li Chen" ],
    [ "CERTIFICATE OF COMPLETION", "Flagger Certification (back)", "Card FL-1" ]
  ].freeze

  def split(item, *certificates)
    ImportItem.transaction { Imports::Splitter.new(item).call(certificates) }
  end

  test "page ranges, file names and page text helpers" do
    assert_equal "3", Imports::Splitter.page_range_for([ 3 ])
    assert_equal "1-2", Imports::Splitter.page_range_for([ 2, 1 ])
    assert_equal "ortiz p1-2.pdf", Imports::Splitter.split_filename("crew.zip/cards/ortiz.pdf", "1-2")
    assert_equal "certificate p3.pdf", Imports::Splitter.split_filename(nil, "3")

    text = marked_text(PAGES)
    assert_equal({ 1 => PAGES[0].join("\n"), 2 => PAGES[1].join("\n"), 3 => PAGES[2].join("\n"), 4 => PAGES[3].join("\n") },
      Imports::Splitter.page_texts(text))
    assert_equal "=== page 3 ===\n#{PAGES[2].join("\n")}\n=== page 4 ===\n#{PAGES[3].join("\n")}",
      Imports::Splitter.text_for_pages(text, [ 3, 4 ])
    assert_equal "no markers", Imports::Splitter.text_for_pages("no markers", [ 1 ])
    assert_equal({}, Imports::Splitter.page_texts(nil))
  end

  test "extract_pages cuts the listed pages out of a PDF" do
    pdf = CombinePDF.parse(synthetic_pdf(PAGES))
    part = CombinePDF.parse(Imports::Splitter.extract_pages(pdf, [ 3, 4 ]))

    assert_equal 2, part.pages.size
  end

  test "a multi-certificate PDF becomes one item per certificate, each with its own pages" do
    item = pdf_item(PAGES, extraction: nil)
    original_blob = item.file.blob
    parts = split(item, certificate_entry(pages: [ 1 ]), certificate_entry(pages: [ 3, 4 ], holder: "Li Chen"))

    first, second = parts.map(&:item)
    assert_equal item, first
    assert_equal [ "1", "3-4" ], [ first.reload.page_range, second.reload.page_range ]
    assert_equal "Li Chen", parts.last.certificate["holder_name"]

    assert_equal "ortiz p1.pdf", first.file.filename.to_s
    assert_equal 1, pdf_page_count(first.file.blob)
    assert_includes pdf_text(first.file.blob), "Juan A. Ortiz"
    assert_not_includes pdf_text(first.file.blob), "COURSE OUTLINE"
    assert_equal "=== page 1 ===\n#{PAGES[0].join("\n")}", first.extracted_text

    assert_equal "ortiz p3-4.pdf", second.file.filename.to_s
    assert_equal 2, pdf_page_count(second.file.blob)
    assert_includes pdf_text(second.file.blob), "Li Chen"
    assert_equal Imports::Splitter.text_for_pages(marked_text(PAGES), [ 3, 4 ]), second.extracted_text

    assert_equal item, second.source_item
    assert_equal [ second ], item.split_items.to_a
    assert_equal [ item.import_batch_id, item.sha256, item.original_filename, "extracting", "fake", 0 ],
      [ second.import_batch_id, second.sha256, second.original_filename, second.status, second.provider, second.ai_units_used ]
    assert_equal({ "certificates" => [ parts.last.certificate ], "non_certificate_pages" => [] }, second.extraction)
    assert_not_equal original_blob.id, first.file.blob.id
  end

  test "pages listed out of order or with gaps use their span; bad pages are ignored" do
    item = pdf_item(PAGES, extraction: nil)
    parts = split(item, certificate_entry(pages: [ 4, "2", 99, 0, "x" ]))

    assert_equal "2-4", parts.first.item.reload.page_range
    assert_equal 3, pdf_page_count(parts.first.item.file.blob)
  end

  test "a certificate covering the whole PDF keeps the file and text" do
    pages = PAGES.first(2)
    item = pdf_item(pages, extraction: nil)
    blob = item.file.blob
    parts = split(item, certificate_entry(pages: [ 1, 2 ]))

    assert_equal "1-2", parts.first.item.reload.page_range
    assert_equal blob, item.file.blob
    assert_equal marked_text(pages), item.extracted_text
  end

  test "no pages listed means the whole file" do
    item = pdf_item(PAGES.first(1), extraction: nil)
    parts = split(item, certificate_entry(pages: []))

    assert_equal "1", parts.first.item.reload.page_range
  end

  test "a certificate after the first that spans the whole file shares the original" do
    item = pdf_item(PAGES.first(2), extraction: nil)
    original_blob = item.file.blob
    parts = split(item, certificate_entry(pages: [ 1 ]), certificate_entry(pages: nil))

    assert_equal [ "1", "1-2" ], parts.map { _1.item.reload.page_range }
    assert_equal original_blob, parts.last.item.file.blob
    assert_equal 2, pdf_page_count(parts.last.item.file.blob)
    assert_equal 1, pdf_page_count(parts.first.item.file.blob)
  end

  test "two certificates on one page each get an item for that page" do
    item = pdf_item(PAGES.first(1), extraction: nil)
    parts = split(item, certificate_entry(pages: [ 1 ]), certificate_entry(pages: [ 1 ], code: "FIRSTAID"))

    assert_equal [ "1", "1" ], parts.map { _1.item.reload.page_range }
    assert_equal 2, ImportItem.where(sha256: item.sha256).count
  end

  test "images are never split: page_range stays nil and the image is shared" do
    item = image_item(extraction: nil)
    parts = split(item, certificate_entry(pages: [ 1 ]), certificate_entry(pages: [ 1 ], holder: "Li Chen"))

    assert_equal [ nil, nil ], parts.map { _1.item.reload.page_range }
    assert_equal [ item.file.blob ] * 2, parts.map { _1.item.file.blob }
    assert_equal "IMG_0042.jpg", item.file.filename.to_s
  end

  test "a PDF combine_pdf can't read keeps the whole file on every item" do
    bytes = "%PDF-1.4\n%%EOF\n"
    item = pipeline_item(bytes:, filename: "broken.pdf", content_type: "application/pdf", extracted_text: marked_text(PAGES.first(2)))
    blob = item.file.blob
    parts = split(item, certificate_entry(pages: [ 1 ]), certificate_entry(pages: [ 2 ]))

    assert_equal [ "1", "2" ], parts.map { _1.item.reload.page_range }
    assert_equal [ blob, blob ], parts.map { _1.item.file.blob }
    assert_equal "=== page 2 ===\n#{PAGES[1].join("\n")}", parts.last.item.extracted_text
  end

  test "a PDF whose nesting overflows combine_pdf's stack keeps the whole file on every item" do
    # An unreferenced 100,000-deep array before a second %%EOF: poppler reads the page, combine_pdf
    # recurses once per level and raises SystemStackError (not a StandardError).
    bytes = synthetic_pdf(PAGES.first(2)) + "\n99 0 obj\n#{"[" * 100_000}#{"]" * 100_000}\nendobj\n%%EOF\n"
    assert_raises(SystemStackError) { CombinePDF.parse(bytes) }
    item = pipeline_item(bytes:, filename: "nested.pdf", content_type: "application/pdf", extracted_text: marked_text(PAGES.first(2)))
    blob = item.file.blob

    parts = split(item, certificate_entry(pages: [ 1 ]), certificate_entry(pages: [ 2 ]))

    assert_equal [ "1", "2" ], parts.map { _1.item.reload.page_range }
    assert_equal [ blob, blob ], parts.map { _1.item.file.blob }
    assert_equal "=== page 2 ===\n#{PAGES[1].join("\n")}", parts.last.item.extracted_text
  end

  test "no certificates, no parts" do
    assert_equal [], Imports::Splitter.new(pdf_item(PAGES, extraction: nil)).call([])
  end

  test "split files are uploaded when the transaction commits" do
    item = pdf_item(PAGES, extraction: nil)
    parts = split(item, certificate_entry(pages: [ 1 ]), certificate_entry(pages: [ 3 ]))

    parts.each do |part|
      reloaded = ImportItem.find(part.item.id)
      assert reloaded.file.blob.service.exist?(reloaded.file.blob.key), "#{reloaded.page_range} was not uploaded"
    end
  end
end
