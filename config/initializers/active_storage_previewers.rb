# Small PDF previews. Active Storage's Poppler previewer stores each PDF's first page as a
# full-page 72 dpi PNG (about 236 KB for a letter scan), kept for as long as the PDF, only so
# thumbnails can be cut from it. This one stores a JPEG whose long side is PREVIEW_SIZE
# pixels instead (about 5 KB). Same tool (pdftoppm), no new gem or package.
#
# The largest image the app makes from a PDF preview is the 160 px thumbnail in
# certificates/_files.html.erb (the import review shows PDFs in the browser's own viewer).
# PREVIEW_SIZE is twice that, so the thumbnail is scaled down from a sharper image and a
# 320 px variant (Certificate's :thumb) would not be blown up. Raise it before showing a
# bigger PDF preview anywhere. A preview already stored stays as it is; purging a blob's
# preview_image makes the next request draw it again.
class PdfThumbnailPreviewer < ActiveStorage::Previewer::PopplerPDFPreviewer
  PREVIEW_SIZE = 320 # pixels, long side
  JPEG_QUALITY = 80

  def preview(**options)
    download_blob_to_tempfile do |input|
      draw_first_page_from input do |output|
        yield io: output, filename: "#{blob.filename.base}.jpg", content_type: "image/jpeg", **options
      end
    end
  end

  private
    def draw_first_page_from(file, &block)
      draw self.class.pdftoppm_path, "-singlefile", "-cropbox", "-scale-to", PREVIEW_SIZE.to_s,
        "-jpeg", "-jpegopt", "quality=#{JPEG_QUALITY},optimize=y", file.path, &block
    end
end

# In Poppler's place, so the MuPDF previewer stays the fallback when pdftoppm is missing.
Rails.application.config.active_storage.previewers = Rails.application.config.active_storage.previewers.map do |previewer|
  previewer == ActiveStorage::Previewer::PopplerPDFPreviewer ? PdfThumbnailPreviewer : previewer
end
