require "test_helper"
require "vips"
require_relative "../../support/scanned_pdf"

class Imports::ExtractTextJobTest < ActiveJob::TestCase
  ORTIZ = ScannedPdf.certificate_text
  REDCROSS_LINK = "https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123".freeze

  setup do
    @dir = Dir.mktmpdir("extract-text-job-test")
    @batch = ImportBatch.create!(uploaded_by: users(:manager), status: :processing, files_count: 1)
  end

  teardown { FileUtils.remove_entry(@dir) }

  test "stores the page-marked text, keeps the item extracting and hands it to the AI step" do
    item = item_with(ScannedPdf.write_text_pdf(file("ortiz.pdf"), [ ORTIZ, "COURSE OUTLINE\nModule 1: Fall protection and ladder safety basics" ]))

    Imports::ExtractTextJob.perform_now(item)

    item.reload
    assert item.extracting?
    assert item.extracted_text.start_with?("=== page 1 ===\nCERTIFICATE OF COMPLETION")
    assert_includes item.extracted_text, "=== page 2 ===\nCOURSE OUTLINE"
    assert_nil item.error_message
    assert_equal [], item.barcodes, "no QR codes on it"
    assert_enqueued_with job: Imports::AiExtractJob, args: [ item ]
  end

  teardown { Array(@resaved_paths).each { FileUtils.rm_f(it) } }

  test "a re-saved copy of an earlier upload is a duplicate: no text read, no AI call, no file kept" do
    first = item_with(resaved("light.png", 1), content_type: "image/png")
    Imports::ExtractTextJob.perform_now(first)
    assert first.reload.content_digest.present?
    clear_enqueued_jobs

    copy = item_with(resaved("heavy.png", 9), content_type: "image/png")

    assert_no_enqueued_jobs(only: Imports::AiExtractJob) { Imports::ExtractTextJob.perform_now(copy) }

    copy.reload
    assert copy.duplicate?
    assert_equal first, copy.duplicate_of
    assert_nil copy.extracted_text
  end

  test "a failed earlier upload doesn't count, and Read again isn't stopped by a copy" do
    failed = item_with(resaved("light.png", 1), content_type: "image/png")
    failed.update!(status: :failed, content_digest: "abc")
    Imports::ExtractTextJob.perform_now(item = item_with(resaved("heavy.png", 9), content_type: "image/png"))
    assert_not item.reload.duplicate?

    other = item_with(resaved("third.png", 6), content_type: "image/png")
    other.update!(content_digest: item.content_digest)
    assert_enqueued_with(job: Imports::AiExtractJob) { Imports::ExtractTextJob.perform_now(other) }
    assert_not other.reload.duplicate?, "it has a digest already: someone asked for a new read"
  end

  test "stores the QR codes with the page numbers of the file" do
    skip_unless_zbarimg
    pdf = item_with(file_fixture("qr/two_pages_qr_on_2.pdf").to_s)
    photo = item_with(file_fixture("qr/redcross_qr.png").to_s, content_type: "image/png")

    Imports::ExtractTextJob.perform_now(pdf)
    Imports::ExtractTextJob.perform_now(photo)

    assert_equal [ { "page" => 2, "text" => REDCROSS_LINK } ], pdf.reload.barcodes
    assert_includes pdf.extracted_text, "=== page 2 ===\nSAMPLE CERTIFICATE"
    assert_equal [ { "page" => 1, "text" => REDCROSS_LINK } ], photo.reload.barcodes
    assert_enqueued_jobs 2, only: Imports::AiExtractJob
  end

  test "stored QR codes are kept, and stored text with none stored is read for QR codes only" do
    skip_unless_zbarimg
    kept = item_with(file_fixture("qr/redcross_qr.png").to_s, content_type: "image/png")
    kept.update!(extracted_text: "=== page 1 ===\nAMERICAN RED CROSS", barcodes: [ { "page" => 1, "text" => "https://example.com/kept" } ])
    text_only = item_with(file_fixture("qr/redcross_qr.png").to_s, content_type: "image/png")
    text_only.update!(extracted_text: "=== page 1 ===\nAMERICAN RED CROSS")

    Imports::ExtractTextJob.perform_now(kept)
    Imports::ExtractTextJob.perform_now(text_only)

    assert_equal [ { "page" => 1, "text" => "https://example.com/kept" } ], kept.reload.barcodes
    assert_equal [ { "page" => 1, "text" => REDCROSS_LINK } ], text_only.reload.barcodes
    assert_equal "=== page 1 ===\nAMERICAN RED CROSS", text_only.extracted_text
    assert_enqueued_jobs 2, only: Imports::AiExtractJob
  end

  test "stored text whose file has gone missing from storage goes on without QR codes" do
    item = item_with(file_fixture("qr/redcross_qr.png").to_s, content_type: "image/png")
    item.update!(extracted_text: "=== page 1 ===\nAMERICAN RED CROSS")
    item.file.blob.service.delete(item.file.blob.key)

    Imports::ExtractTextJob.perform_now(item)

    item.reload
    assert item.extracting?
    assert_nil item.barcodes, "not read"
    assert_enqueued_with job: Imports::AiExtractJob, args: [ item ]
  end

  test "a scanned PDF goes through OCR" do
    item = item_with(ScannedPdf.write(file("scan_0007.pdf"), [ ORTIZ ]))

    Imports::ExtractTextJob.perform_now(item)

    assert_includes item.reload.extracted_text, "Awarded to: Juan A. Ortiz"
    assert_enqueued_jobs 1, only: Imports::AiExtractJob
  end

  test "an image is read using the blob's content type" do
    ScannedPdf.text_image(ORTIZ).write_to_file(file("IMG_0042.png"))
    item = item_with(file("IMG_0042.png"), content_type: "image/png")

    Imports::ExtractTextJob.perform_now(item)

    assert_includes item.reload.extracted_text, "Certificate No: 30-1234567"
  end

  test "an item left extracting by a crashed worker is read again" do
    item = item_with(ScannedPdf.write_text_pdf(file("ortiz.pdf"), [ ORTIZ ]), status: :extracting)

    Imports::ExtractTextJob.perform_now(item)

    assert_includes item.reload.extracted_text, "Juan A. Ortiz"
    assert_enqueued_jobs 1, only: Imports::AiExtractJob
  end

  test "text already stored (an item read again) is used without running the tools" do
    item = item_with(file("corrupt.pdf").tap { |path| File.write(path, "%PDF-1.4 not really a PDF") })
    item.update!(extracted_text: "=== page 1 ===\nCERTIFICATE OF COMPLETION\nAwarded to: Li Chen")

    Imports::ExtractTextJob.perform_now(item)

    item.reload
    assert item.extracting?, "pdftotext would have failed on this file"
    assert_equal "=== page 1 ===\nCERTIFICATE OF COMPLETION\nAwarded to: Li Chen", item.extracted_text
    assert_enqueued_with job: Imports::AiExtractJob, args: [ item ]
  end

  test "items no longer waiting for text are left alone" do
    path = ScannedPdf.write_text_pdf(file("ortiz.pdf"), [ ORTIZ ])

    %i[needs_review accepted rejected failed duplicate].each do |status|
      item = item_with(path, status: status)

      Imports::ExtractTextJob.perform_now(item)

      assert_equal status.to_s, item.reload.status
      assert_nil item.extracted_text
    end
    assert_no_enqueued_jobs only: Imports::AiExtractJob
  end

  test "an unreadable file fails the item with the reason and finishes the batch" do
    File.write(file("broken.pdf"), "%PDF-1.4\nnot really a pdf")
    item = item_with(file("broken.pdf"))

    Imports::ExtractTextJob.perform_now(item)

    item.reload
    assert item.failed?
    assert_match "could not be read as a PDF", item.error_message
    assert_nil item.extracted_text
    assert_no_enqueued_jobs only: Imports::AiExtractJob
    @batch.reload
    assert_equal 1, @batch.error_count
    assert @batch.failed?, "its only item failed"
  end

  test "an unsupported file or a missing file fails the item" do
    File.write(file("notes.txt"), "not a certificate")
    unsupported = item_with(file("notes.txt"), content_type: "text/plain")
    missing = ImportItem.create!(import_batch: @batch, original_filename: "gone.pdf", sha256: Digest::SHA256.hexdigest("gone"))

    Imports::ExtractTextJob.perform_now(unsupported)
    Imports::ExtractTextJob.perform_now(missing)

    assert_match "text/plain is not a supported file type", unsupported.reload.error_message
    assert_equal "The import item has no file attached", missing.reload.error_message
    assert [ unsupported, missing ].all?(&:failed?)
    assert_equal 2, @batch.reload.error_count
  end

  test "a timed-out tool is retried, then fails the item" do
    item = item_with(ScannedPdf.write(file("scan.pdf"), [ ORTIZ ]))
    Imports::ExtractTextJob.tool_timeout = 0.001

    Imports::ExtractTextJob.perform_now(item)
    assert item.reload.extracting?, "waiting for a retry"
    assert_enqueued_jobs 1, only: Imports::ExtractTextJob

    perform_enqueued_jobs(only: Imports::ExtractTextJob) # attempt 2
    assert item.reload.extracting?, "waiting for the last retry"
    perform_enqueued_jobs(only: Imports::ExtractTextJob) # attempt 3

    item.reload
    assert item.failed?
    assert_match "did not finish within 0.001 seconds", item.error_message
    assert_no_enqueued_jobs only: Imports::AiExtractJob
  ensure
    Imports::ExtractTextJob.tool_timeout = Imports::Shell::DEFAULT_TIMEOUT
  end

  test "an unexpected error fails the item, so the batch doesn't wait forever, and is re-raised" do
    item = item_with(ScannedPdf.write_text_pdf(file("ortiz.pdf"), [ ORTIZ ]))
    item.define_singleton_method(:extracting!) { raise ArgumentError, "boom" }

    assert_raises(ArgumentError) { Imports::ExtractTextJob.perform_now(item) }

    item = ImportItem.find(item.id)
    assert item.failed?
    assert_equal "Text extraction failed unexpectedly (ArgumentError): boom", item.error_message
    assert @batch.reload.failed?
  end

  test "a deleted item discards the job" do
    item = item_with(ScannedPdf.write_text_pdf(file("ortiz.pdf"), [ ORTIZ ]))
    Imports::ExtractTextJob.perform_later(item)
    item.destroy!

    assert_nothing_raised { perform_enqueued_jobs(only: Imports::ExtractTextJob) }
    assert_no_enqueued_jobs only: Imports::AiExtractJob
  end

  private
    def resaved(name, compression)
      path = Rails.root.join("tmp", "digest-test-#{SecureRandom.hex(4)}-#{name}").to_s
      Vips::Image.new_from_file(file_fixture("qr/redcross_qr.png").to_s).pngsave(path, compression: compression)
      @resaved_paths = [ *@resaved_paths, path ]
      path
    end

    def file(name)
      File.join(@dir, name)
    end

    def skip_unless_zbarimg
      skip "zbarimg is not installed (apt install zbar-tools); CI has it" unless Certificates::QrReader.available?
    end

    def item_with(path, content_type: "application/pdf", status: :pending)
      bytes = File.binread(path)
      ImportItem.create!(import_batch: @batch, original_filename: File.basename(path), status: status,
        sha256: Digest::SHA256.hexdigest(bytes),
        file: { io: StringIO.new(bytes), filename: File.basename(path), content_type: content_type })
    end
end
