require "test_helper"

class Certificates::ConvertHeicJobTest < ActiveJob::TestCase
  setup do
    @certificate = certificates(:juan_osha30)
  end

  test "replaces a HEIC photo with a JPEG of the same name and purges the original" do
    skip_unless_heif_supported
    heic = attach("certificate.heic")
    attach("certificate.pdf")

    Certificates::ConvertHeicJob.perform_now(@certificate)

    files = @certificate.reload.files.sort_by(&:id)
    assert_equal %w[certificate.pdf certificate.jpg], files.map { |file| file.filename.to_s }
    jpeg = files.last.blob
    assert_equal "image/jpeg", jpeg.content_type
    image = Vips::Image.new_from_buffer(jpeg.download, "")
    assert_equal [ 48, 32 ], [ image.width, image.height ]
    assert_not ActiveStorage::Blob.exists?(heic.id)
    assert_not heic.service.exist?(heic.key)
  end

  test "converts .heif too and is a no-op the second time" do
    skip_unless_heif_supported
    attach("certificate.heic", filename: "IMG_0042.HEIF", content_type: "image/heif")

    Certificates::ConvertHeicJob.perform_now(@certificate)
    assert_no_difference -> { ActiveStorage::Blob.count } do
      Certificates::ConvertHeicJob.perform_now(@certificate)
    end

    assert_equal [ "IMG_0042.jpg" ], @certificate.reload.files.map { |file| file.filename.to_s }
  end

  test "swapping the file does not queue another conversion" do
    skip_unless_heif_supported
    attach("certificate.heic")

    assert_no_enqueued_jobs(only: Certificates::ConvertHeicJob) do
      Certificates::ConvertHeicJob.perform_now(@certificate)
    end
  end

  test "leaves other files alone" do
    attach("certificate.jpg")
    attach("certificate.pdf")

    assert_no_difference -> { ActiveStorage::Attachment.count } do
      Certificates::ConvertHeicJob.perform_now(@certificate)
    end
    assert_equal %w[certificate.jpg certificate.pdf], @certificate.reload.files.map { |file| file.filename.to_s }.sort
  end

  test "a conversion that loses the race to another worker throws its JPEG away" do
    skip_unless_heif_supported
    attach("certificate.heic")
    attachment = @certificate.files_attachments.first
    ActiveStorage::Attachment.where(id: attachment.id).delete_all # another worker already swapped it

    assert_no_difference -> { ActiveStorage::Blob.count } do
      Certificates::ConvertHeicJob.new.send(:convert, @certificate, attachment)
    end
    assert_empty @certificate.reload.files
  end

  test "saving a certificate with a HEIC file queues the conversion; other files don't" do
    certificate = Certificate.new(crew_member: crew_members(:maria_garcia), certificate_type: certificate_types(:flagger),
      completed_on: Date.current)
    certificate.files.attach(blob("certificate.heic"))
    assert_enqueued_with(job: Certificates::ConvertHeicJob, args: [ certificate ]) { certificate.save! }

    other = certificates(:maria_osha30)
    assert_no_enqueued_jobs(only: Certificates::ConvertHeicJob) do
      other.files.attach(blob("certificate.jpg"))
      other.update!(notes: "Front and back")
    end
  end

  test "attaching a HEIC file to a saved certificate queues the conversion once" do
    assert_enqueued_jobs 1, only: Certificates::ConvertHeicJob do
      @certificate.files.attach(blob("certificate.heic"))
    end

    # Analyzing the blob touches the certificate; that must not queue another conversion.
    assert_no_enqueued_jobs(only: Certificates::ConvertHeicJob) do
      @certificate.files.first.blob.analyze
      @certificate.reload.update!(notes: "Checked")
    end
  end

  private
    def blob(name, filename: name, content_type: nil)
      ActiveStorage::Blob.create_and_upload!(io: file_fixture(name).open, filename: filename, content_type: content_type)
    end

    # Attached without callbacks so the after-commit enqueue doesn't interfere.
    def attach(name, **options)
      blob(name, **options).tap do |created|
        ActiveStorage::Attachment.create!(record: @certificate, name: "files", blob: created)
      end
    end

    # CI and production use libvips with libheif's HEVC decoder; skip where it's missing.
    def skip_unless_heif_supported
      require "vips"
      skip "libvips #{Vips.version_string} has no HEIF loader; HEIC conversion not tested" if Vips.type_find("VipsOperation", "heifload").zero?
    rescue LoadError => error
      skip "libvips is not installed (#{error.message}); HEIC conversion not tested"
    end
end
