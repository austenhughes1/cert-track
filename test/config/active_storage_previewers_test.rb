require "test_helper"
require "support/scanned_pdf"

# config/initializers/active_storage_previewers.rb: PDF previews are a small JPEG, not a
# full-page PNG. Runs the real pdftoppm on real PDFs.
class ActiveStoragePreviewersTest < ActiveSupport::TestCase
  setup do
    skip "pdftoppm is not installed; PDF previews not tested" unless PdfThumbnailPreviewer.pdftoppm_exists?
  end

  test "PDFs go to the small previewer, in Poppler's place before the MuPDF fallback" do
    previewers = ActiveStorage.previewers

    assert_not_includes previewers, ActiveStorage::Previewer::PopplerPDFPreviewer
    assert_operator previewers.index(PdfThumbnailPreviewer), :<, previewers.index(ActiveStorage::Previewer::MuPDFPreviewer)
    assert_equal PdfThumbnailPreviewer, previewers.find { |previewer| previewer.accept?(pdf_blob(file_fixture("certificate.pdf").binread)) }
  end

  test "stores the first page as a 320 px JPEG and cuts the 160 px thumbnail from it" do
    blob = pdf_blob(file_fixture("certificate.pdf").binread) # one 288 x 180 pt page

    thumbnail = blob.preview(resize_to_limit: [ 160, 160 ]).processed

    image = blob.reload.preview_image
    assert_equal "image/jpeg", image.content_type
    assert_equal "certificate.jpg", image.filename.to_s
    assert_equal [ 320, 200 ], dimensions(image.download)
    assert_equal [ 160, 100 ], dimensions(thumbnail.download)
  end

  test "a letter-size scan's preview is a few KB, far smaller than Poppler's PNG" do
    Dir.mktmpdir do |dir|
      path = ScannedPdf.write(File.join(dir, "scan.pdf"), [ ScannedPdf.certificate_text, "Page two" ])
      blob = pdf_blob(File.binread(path))

      blob.preview(resize_to_limit: [ 160, 160 ]).processed

      image = blob.reload.preview_image
      width, height = dimensions(image.download)
      assert_equal 320, height
      assert_in_delta 612 * 320 / 792.0, width, 1 # 612 x 792 pt; pdftoppm rounds up
      assert_operator image.byte_size, :<, 20.kilobytes
      assert_operator image.byte_size * 5, :<, stock_preview_size(blob)
    end
  end

  private
    def pdf_blob(bytes)
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: "certificate.pdf", content_type: "application/pdf")
    end

    def dimensions(bytes)
      image = Vips::Image.new_from_buffer(bytes, "")
      [ image.width, image.height ]
    end

    # Bytes of the full-page PNG Active Storage's own Poppler previewer would have stored.
    def stock_preview_size(blob)
      size = nil
      ActiveStorage::Previewer::PopplerPDFPreviewer.new(blob).preview { |attachable| size = attachable[:io].size }
      size
    end
end
