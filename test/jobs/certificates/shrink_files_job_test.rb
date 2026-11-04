require "test_helper"
require_relative "../../support/scanned_pdf"

class Certificates::ShrinkFilesJobTest < ActiveJob::TestCase
  setup do
    @certificate = certificates(:juan_osha30)
  end

  test "a big photo becomes a JPEG within 2400 px with the same name, and the original is purged" do
    photo = attach(jpeg(noise(3600, 2400), quality: 95), "IMG_0042.JPG", "image/jpeg")
    pdf = attach(file_fixture("certificate.pdf").binread, "certificate.pdf", "application/pdf")

    shrink(photo, pdf)

    files = @certificate.reload.files.sort_by(&:id)
    assert_equal %w[certificate.pdf IMG_0042.jpg], files.map { |file| file.filename.to_s }
    assert_equal pdf.blob, files.first.blob, "a PDF made on a computer stays as it is"
    copy = files.last.blob
    assert_equal [ "image/jpeg", true ], [ copy.content_type, copy.metadata["shrunk"] ]
    assert_operator copy.byte_size, :<, photo.blob.byte_size * 0.8
    assert_equal [ 2400, 1600 ], dimensions(copy)
    assert_not ActiveStorage::Blob.exists?(photo.blob.id)
    assert_not photo.blob.service.exist?(photo.blob.key)
  end

  test "PNG and WEBP photos become JPEGs when that saves enough" do
    png = attach(noise(1200, 900).pngsave_buffer, "card.png", "image/png")
    webp = attach(noise(1200, 900).webpsave_buffer(lossless: true), "card.webp", "image/webp")

    shrink(png, webp)

    assert_equal [ [ "card.jpg", "image/jpeg" ] ] * 2, @certificate.reload.files.map { |file| [ file.filename.to_s, file.content_type ] }
  end

  test "a photo without metadata that wouldn't shrink by 20% is kept as it is" do
    small = attach(jpeg(noise(1000, 800), quality: 60, strip: true), "small.jpg", "image/jpeg")
    barely = attach(jpeg(noise(2500, 1000), quality: 75, strip: true), "barely.jpg", "image/jpeg")

    assert_no_difference -> { ActiveStorage::Blob.count } do
      shrink(small, barely)
    end
    assert_equal [ small.blob, barely.blob ].sort_by(&:id), @certificate.reload.files.blobs.sort_by(&:id)
  end

  test "a phone photo that wouldn't shrink by 20% is still replaced, without its GPS location" do
    image = noise(1600, 1200).copy
    image.set_type(GObject::GSTR_TYPE, "exif-ifd0-Model", "iPhone 15")
    image.set_type(GObject::GSTR_TYPE, "exif-ifd3-GPSLatitude", "39/1 44/1 0/1")
    image.set_type(GObject::GSTR_TYPE, "exif-ifd3-GPSLatitudeRef", "N")
    photo = attach(jpeg(image, quality: 70), "IMG_0042.JPG", "image/jpeg")
    assert_includes Vips::Image.new_from_buffer(photo.blob.download, "").get_fields, "exif-ifd3-GPSLatitude"

    shrink(photo)

    copy = @certificate.reload.files.sole.blob
    assert_not_equal photo.blob, copy
    assert_operator copy.byte_size, :>=, photo.blob.byte_size * 0.8, "not replaced for its size"
    assert_empty Vips::Image.new_from_buffer(copy.download, "").get_fields.grep(/exif|xmp|iptc|GPS/)
    assert_not ActiveStorage::Blob.exists?(photo.blob.id)
  end

  test "HEIC and HEIF photos are always converted, even when the JPEG is bigger" do
    skip_unless_heif_supported
    heic = attach(file_fixture("certificate.heic").binread, "certificate.heic", "image/heic")
    heif = attach(heic_bytes, "IMG_0042.HEIF", "image/heif")

    shrink(heic, heif)

    files = @certificate.reload.files.sort_by { |file| file.filename.to_s }
    assert_equal [ [ "IMG_0042.jpg", "image/jpeg" ], [ "certificate.jpg", "image/jpeg" ] ],
      files.map { |file| [ file.filename.to_s, file.content_type ] }
    assert_operator files.first.blob.byte_size, :>, heif.blob.byte_size
    assert_equal [ [ 800, 600 ], [ 48, 32 ] ], files.map { |file| dimensions(file.blob) }
  end

  test "a scanned PDF is re-encoded and keeps its name" do
    page = ScannedPdf.text_image(ScannedPdf.certificate_text) # a letter page at 300 dpi
    scan = attach(ScannedPdf.image_pdf([ [ page, ScannedPdf.jpeg_bytes(page) ] ], dpi: ScannedPdf::DPI), "scan.pdf", "application/pdf")

    shrink(scan)

    copy = @certificate.reload.files.sole.blob
    assert_equal [ "scan.pdf", "application/pdf", true ], [ copy.filename.to_s, copy.content_type, copy.metadata["shrunk"] ]
    assert_operator copy.byte_size, :<, scan.blob.byte_size * 0.8
    assert_not ActiveStorage::Blob.exists?(scan.blob.id)
  end

  test "only the attachments it was given are shrunk" do
    given = attach(photo_bytes, "given.jpg", "image/jpeg")
    other = attach(photo_bytes, "other.jpg", "image/jpeg")

    Certificates::ShrinkFilesJob.perform_now(@certificate, [ given.id ])

    assert ActiveStorage::Attachment.exists?(other.id)
    assert_not ActiveStorage::Attachment.exists?(given.id)
  end

  test "a second run and a copy it made are both no-ops" do
    photo = attach(photo_bytes, "photo.jpg", "image/jpeg")
    shrink(photo)
    copy = @certificate.reload.files_attachments.sole
    copy.blob.analyze # as Active Storage does after the attach; the mark survives it
    assert copy.blob.reload.metadata["shrunk"]

    assert_no_difference -> { ActiveStorage::Blob.count } do
      shrink(photo)
      shrink(copy) # marked as shrunk, so never processed again
    end
    assert_equal copy, @certificate.reload.files_attachments.sole
  end

  test "swapping the file does not queue another shrink" do
    photo = attach(photo_bytes, "photo.jpg", "image/jpeg")

    assert_no_enqueued_jobs(only: Certificates::ShrinkFilesJob) { shrink(photo) }
  end

  test "a shrink that loses the race to another worker throws its copy away" do
    photo = attach(photo_bytes, "photo.jpg", "image/jpeg")
    ActiveStorage::Attachment.where(id: photo.id).delete_all # another worker already swapped it

    assert_no_difference -> { ActiveStorage::Blob.count } do
      Certificates::ShrinkFilesJob.new.send(:shrink, @certificate, photo)
    end
    assert_empty @certificate.reload.files
  end

  test "a file another record still uses is not deleted" do
    photo = attach(photo_bytes, "photo.jpg", "image/jpeg")
    other = certificates(:maria_osha30)
    ActiveStorage::Attachment.create!(record: other, name: "files", blob: photo.blob)

    shrink(photo)

    assert_equal [ "photo.jpg" ], @certificate.reload.files.map { |file| file.filename.to_s }
    assert_not_equal photo.blob, @certificate.files.sole.blob
    assert_equal photo.blob, other.reload.files.sole.blob
  end

  test "a file that can't be read is kept" do
    broken = attach("not really a JPEG", "broken.jpg", "image/jpeg")

    assert_nothing_raised { shrink(broken) }
    assert_equal broken.blob, @certificate.reload.files.sole.blob
  end

  test "saving a certificate with files queues the job for those attachments" do
    certificate = Certificate.new(crew_member: crew_members(:maria_garcia), certificate_type: certificate_types(:flagger),
      completed_on: Date.current)
    certificate.files.attach(blob("certificate.heic"), blob("certificate.pdf"))

    certificate.save!

    assert_enqueued_with(job: Certificates::ShrinkFilesJob, args: [ certificate, certificate.files_attachments.order(:id).ids ])
  end

  test "attaching to a saved certificate queues the job once, for the new file only" do
    existing = attach(file_fixture("certificate.pdf").binread, "certificate.pdf", "application/pdf")

    assert_enqueued_jobs 1, only: Certificates::ShrinkFilesJob do
      @certificate.files.attach(blob("certificate.jpg"))
    end
    added = @certificate.files_attachments.where.not(id: existing.id).sole
    assert_enqueued_with(job: Certificates::ShrinkFilesJob, args: [ @certificate, [ added.id ] ])

    # Analyzing the blob touches the certificate, and other edits attach nothing: no new job.
    assert_no_enqueued_jobs(only: Certificates::ShrinkFilesJob) do
      added.blob.analyze
      @certificate.reload.update!(notes: "Checked")
    end
  end

  private
    def shrink(*attachments)
      Certificates::ShrinkFilesJob.perform_now(@certificate, attachments.map(&:id))
    end

    def blob(name)
      ActiveStorage::Blob.create_and_upload!(io: file_fixture(name).open, filename: name)
    end

    # Attached without callbacks so the after-commit enqueue doesn't interfere.
    def attach(bytes, filename, content_type)
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: filename, content_type: content_type,
        identify: false)
      ActiveStorage::Attachment.create!(record: @certificate, name: "files", blob: blob)
    end

    def dimensions(blob)
      image = Vips::Image.new_from_buffer(blob.download, "")
      [ image.width, image.height ]
    end

    # libvips writes a small EXIF block unless strip is set, as a camera or phone does.
    def jpeg(image, quality:, strip: false)
      image.jpegsave_buffer(Q: quality, strip: strip)
    end

    # A photo that shrinks well below 80% at quality 80.
    def photo_bytes
      @photo_bytes ||= jpeg(noise(1600, 1200), quality: 95)
    end

    # Random pixels don't compress, like the detail in a phone photo.
    def noise(width, height)
      Vips::Image.gaussnoise(width, height, mean: 128, sigma: 40).bandjoin([ Vips::Image.gaussnoise(width, height, mean: 100, sigma: 30) ] * 2)
        .cast(:uchar).copy(interpretation: :srgb)
    end

    # A phone-style HEIC, smaller than a quality-80 JPEG of the same pixels can be.
    def heic_bytes
      noise(800, 600).heifsave_buffer(compression: :hevc, Q: 30)
    rescue Vips::Error
      skip "libvips #{Vips.version_string} can't write HEIC; the bigger-JPEG case is not tested"
    end

    # CI and production use libvips with libheif's HEVC decoder; skip where it's missing.
    def skip_unless_heif_supported
      skip "libvips #{Vips.version_string} has no HEIF loader; HEIC conversion not tested" if Vips.type_find("VipsOperation", "heifload").zero?
    end
end
