require "test_helper"

class Certificates::ReadQrCodesJobTest < ActiveJob::TestCase
  REDCROSS_LINK = "https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123".freeze

  setup do
    CertificateIssuer.seed_defaults!
    @certificate = certificates(:juan_osha30)
    @redcross = CertificateIssuer.find_by_code("REDCROSS")
    @training = CertificateIssuer.find_by_code("360TRAINING")
  end

  test "a certificate without a link takes the QR link on an issuer's domain, and that issuer, then is checked" do
    skip_unless_zbarimg
    assert_nil @certificate.verification_url

    perform(attach("redcross_qr.png"))

    @certificate.reload
    assert_equal REDCROSS_LINK, @certificate.verification_url
    assert_equal @redcross, @certificate.certificate_issuer
    assert_enqueued_with job: Verification::CheckJob, args: [ @certificate ]
  end

  test "the QR link on the certificate's own issuer's domain comes first" do
    skip_unless_zbarimg
    @certificate.update!(certificate_issuer: @training)

    perform(attach("redcross_qr.png"), attach("360training_qr.png"))

    assert_match %r{\Ahttps://verify\.360training\.com/}, @certificate.reload.verification_url
    assert_equal @training, @certificate.certificate_issuer
  end

  test "with no QR link on its own issuer's domain, another issuer's link is used and its issuer kept" do
    skip_unless_zbarimg
    @certificate.update!(certificate_issuer: @training)

    perform(attach("redcross_qr.png"))

    assert_equal REDCROSS_LINK, @certificate.reload.verification_url
    assert_equal @training, @certificate.certificate_issuer
  end

  test "a link the certificate has is kept" do
    skip_unless_zbarimg
    @certificate.update!(verification_url: "https://www.redcross.org/take-a-class/qrcode?certnumber=TYPED")

    perform(attach("360training_qr.png"))

    assert_equal "https://www.redcross.org/take-a-class/qrcode?certnumber=TYPED", @certificate.reload.verification_url
    assert_nil @certificate.certificate_issuer
    assert_enqueued_with job: Verification::CheckJob, args: [ @certificate ]
  end

  test "a confirmed fake certificate keeps the details the person checked: no link or issuer is filled in, and it stays fake" do
    skip_unless_zbarimg
    @certificate.update!(verification_code: "MADEUP1")
    @certificate.record_authenticity!(status: :not_found, method: "person", note: "Number is made up", by: users(:manager))

    perform(attach("redcross_qr.png"))

    @certificate.reload
    assert_equal [ nil, nil ], [ @certificate.verification_url, @certificate.certificate_issuer ]
    assert_equal [ "not_found", "person", "Number is made up" ],
      [ @certificate.authenticity_status, @certificate.authenticity_method, @certificate.authenticity_note ]
    assert_enqueued_with job: Verification::CheckJob, args: [ @certificate ] # it leaves a person's result alone
  end

  test "the crew member is locked before the certificate's row, as Verification::Run and Certificate's saves do" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    Certificates::ReadQrCodesJob.new.send(:assign_verification_link, Certificate.find(@certificate.id), [ REDCROSS_LINK ])
    ActiveSupport::Notifications.unsubscribe(subscriber)

    member_lock = statements.index { it.match?(/FROM "crew_members".*FOR UPDATE/m) }
    row_lock = statements.index { it.match?(/FROM "certificates".*FOR UPDATE/m) }
    assert member_lock && row_lock, statements.join("\n")
    assert_operator member_lock, :<, row_lock
    assert_equal REDCROSS_LINK, @certificate.reload.verification_url
  end

  test "a lookalike or unrelated QR link sets nothing, and the check still runs (it flags the lookalike)" do
    skip_unless_zbarimg

    perform(attach("lookalike_qr.png"), attach("unrelated_qr.png"))

    @certificate.reload
    assert_nil @certificate.verification_url
    assert_nil @certificate.certificate_issuer
    assert_enqueued_with job: Verification::CheckJob, args: [ @certificate ]
  end

  test "files without QR codes change nothing, and the check still runs" do
    attachment = attach("code128.png")

    assert_no_changes -> { @certificate.reload.attributes } do
      perform(attachment)
    end
    assert_enqueued_with job: Verification::CheckJob, args: [ @certificate ]
  end

  test "only the attachments it was given are read" do
    skip_unless_zbarimg
    attach("redcross_qr.png")

    perform(attach("unrelated_qr.png"))

    assert_nil @certificate.reload.verification_url
  end

  test "when the shrink job replaced a file first, the certificate's current files are read" do
    skip_unless_zbarimg
    original = attach("redcross_qr.png")
    # What Certificates::ShrinkFilesJob does: a new attachment for the copy, the old one deleted.
    copy = blob("redcross_qr.png", metadata: { "shrunk" => true })
    ActiveStorage::Attachment.create!(record: @certificate, name: "files", blob: copy)
    original.delete

    perform(original)

    assert_equal REDCROSS_LINK, @certificate.reload.verification_url
  end

  test "a certificate deleted before the job ran discards it" do
    attachment = attach("redcross_qr.png")
    Certificates::ReadQrCodesJob.perform_later(@certificate, [ attachment.id ])
    @certificate.destroy!

    assert_nothing_raised { perform_enqueued_jobs(only: Certificates::ReadQrCodesJob) }
    assert_no_enqueued_jobs only: Verification::CheckJob
  end

  test "saving a certificate with files queues the job for those attachments, ahead of the shrink job" do
    certificate = Certificate.new(crew_member: crew_members(:maria_garcia), certificate_type: certificate_types(:flagger),
      completed_on: Date.current)
    certificate.files.attach(blob("redcross_qr.png"), blob("two_pages_qr_on_2.pdf"))

    certificate.save!

    ids = certificate.files_attachments.order(:id).ids
    assert_enqueued_with(job: Certificates::ReadQrCodesJob, args: [ certificate, ids ])
    jobs = enqueued_jobs.map { |job| job["job_class"] }
    assert_operator jobs.index("Certificates::ReadQrCodesJob"), :<, jobs.index("Certificates::ShrinkFilesJob")
  end

  test "attaching to a saved certificate queues the job once, for the new file only" do
    existing = attach("redcross_qr.png")

    assert_enqueued_jobs 1, only: Certificates::ReadQrCodesJob do
      @certificate.files.attach(blob("360training_qr.png"))
    end
    added = @certificate.files_attachments.where.not(id: existing.id).sole
    assert_enqueued_with(job: Certificates::ReadQrCodesJob, args: [ @certificate, [ added.id ] ])

    # Analyzing the blob touches the certificate, and other edits attach nothing: no new job.
    assert_no_enqueued_jobs(only: Certificates::ReadQrCodesJob) do
      added.blob.analyze
      @certificate.reload.update!(notes: "Checked")
    end
  end

  test "a certificate an import creates is not read again, but a file added to it later is" do
    certificate = Certificate.create!(crew_member: crew_members(:maria_garcia), certificate_type: certificate_types(:flagger),
      completed_on: Date.current, source: :import, files: [ blob("redcross_qr.png") ])

    assert_no_enqueued_jobs only: Certificates::ReadQrCodesJob
    assert_enqueued_jobs 1, only: Certificates::ShrinkFilesJob

    assert_enqueued_jobs 1, only: Certificates::ReadQrCodesJob do
      certificate.files.attach(blob("360training_qr.png"))
    end
  end

  private
    def perform(*attachments)
      Certificates::ReadQrCodesJob.perform_now(@certificate, attachments.map(&:id))
    end

    def blob(name, metadata: {})
      ActiveStorage::Blob.create_and_upload!(io: file_fixture("qr/#{name}").open, filename: name, metadata: metadata)
    end

    # Attached without callbacks so the after-commit enqueue doesn't interfere.
    def attach(name)
      ActiveStorage::Attachment.create!(record: @certificate, name: "files", blob: blob(name))
    end

    def skip_unless_zbarimg
      skip "zbarimg is not installed (apt install zbar-tools); CI has it" unless Certificates::QrReader.available?
    end
end
