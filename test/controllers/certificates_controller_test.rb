require "test_helper"

class CertificatesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @juan = crew_members(:juan_ortiz)
    @flagger = certificate_types(:flagger)
  end

  # --- show / new ---

  test "Other... for the type adds it from the typed name, and a manager can use it" do
    sign_in_as users(:manager)

    assert_difference -> { CertificateType.count } do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(certificate_type_id: "other", other_type_name: "Scaffold Safety") }
    end

    certificate = @juan.certificates.order(:id).last
    assert_equal "Scaffold Safety", certificate.certificate_type.name
    assert_equal certificate.completed_on.advance(months: 24), certificate.expires_on
    assert_match "Scaffold Safety was added to the certificate types", flash[:notice]
    assert_nil CertificateType.find_by(name: "Other")
  end

  test "Other... for the type needs a name, a failed save adds no type, and viewers can't use it" do
    sign_in_as users(:manager)

    assert_no_difference -> { CertificateType.count } do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(certificate_type_id: "other", other_type_name: " ") }
      assert_response :unprocessable_entity
      assert_select "#error_explanation", /new certificate type's name/
      assert_select "select[name=?] option[value=other]", "certificate[certificate_type_id]"

      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(certificate_type_id: "other", other_type_name: "Scaffold Safety", completed_on: "") }
      assert_response :unprocessable_entity
      assert_select "select[name=?] option[value=other][selected]", "certificate[certificate_type_id]"
      assert_select "input[name=?][value=?]", "certificate[other_type_name]", "Scaffold Safety"
    end

    sign_out
    sign_in_as users(:viewer)
    assert_no_difference -> { CertificateType.count } do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(certificate_type_id: "other", other_type_name: "Scaffold Safety") }
    end
    assert_response :forbidden
  end

  test "the No expiration box saves a certificate with no expiry, whatever the type's validity" do
    sign_in_as users(:manager)

    certificate = no_expiration_certificate

    assert certificate.expiry_no_expiration?
    assert_nil certificate.expires_on

    get edit_crew_member_certificate_path(@juan, certificate)
    assert_select "input[type=checkbox][name=?][checked]", "certificate[no_expiration]"
    get crew_member_certificate_path(@juan, certificate)
    assert_match "the certificate says it has no expiration", response.body
  end

  test "viewer sees a certificate with its files and history" do
    certificate = certificates(:juan_flagger)
    certificate.files.attach(fixture_blob("certificate.pdf"), fixture_blob("certificate.jpg"))
    sign_in_as users(:viewer)

    get crew_member_certificate_path(@juan, certificate)

    assert_response :success
    assert_select "title", text: /Flagger · Juan Ortiz/
    assert_select "#files li", 2
    assert_select "#files a[href*='disposition=attachment']", 2
    assert_select "#history tr##{ActionView::RecordIdentifier.dom_id(certificates(:juan_flagger_old), :history)}"
    assert_select "a", text: "Edit", count: 0
    assert_select "button", text: "Remove", count: 0
  end

  test "show renders image, PDF and HEIC thumbnails and an icon for other files" do
    certificate = certificates(:juan_osha30)
    %w[certificate.jpg certificate.png certificate.webp certificate.heic certificate.pdf].each do |name|
      certificate.files.attach(fixture_blob(name))
    end
    # Something with no representation, attached without validation.
    ActiveStorage::Attachment.create!(record: certificate, name: "files",
      blob: ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x"), filename: "scan.bin", content_type: "application/octet-stream"))
    sign_in_as users(:manager)

    get crew_member_certificate_path(@juan, certificate)

    assert_response :success
    assert_select "#files li", 6
    assert_select "#files img[src*='/rails/active_storage/representations/redirect/']", 5
    assert_select "#files li", text: /BIN/
    assert_select "#files", text: /Converting to JPG/
    assert_select "#files button", text: "Remove", count: 6
  end

  test "superseded certificate links to the current one" do
    sign_in_as users(:viewer)

    get crew_member_certificate_path(@juan, certificates(:juan_flagger_old))

    assert_response :success
    assert_select "#superseded_notice a[href=?]", crew_member_certificate_path(@juan, certificates(:juan_flagger))
  end

  test "certificates are scoped to their crew member" do
    sign_in_as users(:viewer)

    get crew_member_certificate_path(crew_members(:maria_garcia), certificates(:juan_flagger))

    assert_response :not_found
  end

  test "new preselects the requested type and labels validity" do
    sign_in_as users(:manager)

    get new_crew_member_certificate_path(@juan, certificate_type_id: @flagger.id)

    assert_response :success
    assert_select "title", text: /Add certificate · Juan Ortiz/
    assert_select "select#certificate_certificate_type_id option[selected][value=?]", @flagger.id.to_s
    assert_select "option", text: /Flagger \(FLAGGER\) · valid 36 months/
    assert_select "option", text: /never expires/
    assert_select "option", text: /HAZWOPER/, count: 0 # inactive types are not offered
    assert_select "#expires_on_hint", text: /plus 36 months for Flagger/
    assert_select "input[type=file][multiple][data-direct-upload-url][data-file-drop-target=input]"
    assert_select "[data-controller=file-drop]"
  end

  # --- create ---

  test "create with several direct-uploaded files" do
    sign_in_as users(:manager)

    assert_difference -> { Certificate.count } => 1, -> { ActiveStorage::Attachment.count } => 3 do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(
        files: [ "", direct_upload("certificate.pdf"), direct_upload("certificate.jpg"), direct_upload("certificate.png") ]
      ) }
    end

    certificate = Certificate.order(:id).last
    assert_redirected_to crew_member_certificate_path(@juan, certificate)
    assert_equal %w[certificate.jpg certificate.pdf certificate.png], certificate.files.map { |file| file.filename.to_s }.sort
    assert_equal users(:manager), certificate.verified_by
    assert_in_delta Time.current, certificate.verified_at, 5.seconds
    assert certificate.source_manual?
    assert_equal "FL-90001", certificate.certificate_number
  end

  test "create accepts plain multipart uploads when JavaScript is off" do
    sign_in_as users(:admin)

    post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(
      files: [ fixture_file_upload("certificate.webp", "image/webp"), fixture_file_upload("certificate.pdf", "application/pdf") ]
    ) }

    certificate = Certificate.order(:id).last
    assert_redirected_to crew_member_certificate_path(@juan, certificate)
    assert_equal 2, certificate.files.count
  end

  test "create without files is fine" do
    sign_in_as users(:manager)

    assert_difference "Certificate.count", 1 do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(files: [ "" ]) }
    end
    assert_empty Certificate.order(:id).last.files
  end

  test "a HEIC upload is kept until the shrink job converts it" do
    sign_in_as users(:manager)

    post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(files: [ direct_upload("certificate.heic") ]) }

    certificate = Certificate.order(:id).last
    assert_equal "image/heic", certificate.files.first.content_type
    assert_enqueued_with(job: Certificates::ShrinkFilesJob, args: [ certificate, certificate.files_attachments.ids ])
  end

  test "a blank expiry is computed from the type's validity" do
    sign_in_as users(:manager)

    post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(expires_on: "") }

    certificate = Certificate.order(:id).last
    assert_equal Date.current.advance(months: 36), certificate.expires_on
    assert certificate.expiry_computed?
  end

  test "a newer certificate supersedes the current one" do
    old = certificates(:juan_flagger)
    sign_in_as users(:manager)

    post crew_member_certificates_path(@juan), params: { certificate: valid_attributes }

    created = Certificate.order(:id).last
    assert created.current?
    assert old.reload.superseded?
    assert_equal created, @juan.current_certificate_for(@flagger)
    assert_equal "Added Flagger for Juan Ortiz.", flash[:notice]
  end

  test "an older certificate is saved as history" do
    current = certificates(:juan_flagger)
    sign_in_as users(:manager)

    post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(completed_on: current.completed_on - 1.year) }

    assert Certificate.order(:id).last.superseded?
    assert current.reload.current?
    assert_match "kept as history", flash[:notice]
  end

  test "a file type outside the allowlist is rejected" do
    sign_in_as users(:manager)

    assert_no_difference -> { Certificate.count } do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(files: [ direct_upload("notes.txt") ]) }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", text: /notes\.txt must be a PDF, JPG, PNG, HEIC or WEBP/
  end

  test "the content type comes from the file's bytes, not the browser's claim" do
    sign_in_as users(:manager)
    zip = "PK\x03\x04".b + ("\0" * 64)

    post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(
      files: [ direct_upload_data(zip, filename: "card.png", content_type: "image/png") ]
    ) }

    assert_response :unprocessable_entity
    assert_select "#error_explanation", text: /card\.png must be a PDF/
  end

  test "a file over 25 MB is rejected" do
    sign_in_as users(:manager)
    signed_id = direct_upload("certificate.pdf")
    ActiveStorage::Blob.find_signed!(signed_id).update_columns(byte_size: 25.megabytes + 1)

    assert_no_difference -> { Certificate.count } do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(files: [ signed_id ]) }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", text: /certificate\.pdf is larger than 25 MB/
  end

  test "after a validation error, good uploads are carried over and bad ones dropped" do
    sign_in_as users(:manager)
    good = direct_upload("certificate.jpg")
    bad = direct_upload("notes.txt")

    post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(completed_on: "", files: [ good, bad ]) }

    assert_response :unprocessable_entity
    assert_select "#carried_over_files input[type=hidden][name='certificate[files][]']", 1
    assert_select "#carried_over_files input[value=?]", ActiveStorage::Blob.find_signed!(good).signed_id
    assert_select "#carried_over_files", text: /certificate\.jpg/
  end

  test "a tampered signed id shows an error instead of failing" do
    sign_in_as users(:manager)

    assert_no_difference -> { Certificate.count } do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(files: [ "not-a-signed-id" ]) }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", text: /could not be read/
  end

  test "invalid fields re-render the form with errors" do
    sign_in_as users(:manager)

    post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(completed_on: (Date.current + 1).iso8601) }

    assert_response :unprocessable_entity
    assert_select "#error_explanation", text: /can't be in the future/
  end

  # --- edit / update ---

  test "edit shows attached files with remove buttons outside the form" do
    certificate = certificates(:juan_osha30)
    certificate.files.attach(fixture_blob("certificate.pdf"))
    sign_in_as users(:manager)

    get edit_crew_member_certificate_path(@juan, certificate)

    assert_response :success
    assert_select "title", text: /Edit OSHA/
    assert_select "section[aria-labelledby=attached_files_heading] button", text: "Remove", count: 1
    assert_select "form[action=?] button", crew_member_certificate_path(@juan, certificate), text: "Remove", count: 0
  end

  test "update appends files instead of replacing them" do
    certificate = certificates(:juan_osha30)
    certificate.files.attach(fixture_blob("certificate.pdf"))
    pdf = certificate.files_attachments.sole
    sign_in_as users(:manager)

    patch crew_member_certificate_path(@juan, certificate), params: { certificate: {
      issued_by: "OSHA Training Institute", files: [ "", direct_upload("certificate.jpg"), direct_upload("certificate.png") ]
    } }

    assert_redirected_to crew_member_certificate_path(@juan, certificate)
    certificate.reload
    assert_equal %w[certificate.jpg certificate.pdf certificate.png], certificate.files.map { |file| file.filename.to_s }.sort
    added = certificate.files_attachments.where.not(id: pdf.id).order(:id).ids
    assert_enqueued_with(job: Certificates::ShrinkFilesJob, args: [ certificate, added ]) # not the PDF again
    assert_equal "OSHA Training Institute", certificate.issued_by
    assert_equal users(:manager), certificate.verified_by
  end

  test "update without files keeps the existing ones" do
    certificate = certificates(:juan_osha30)
    certificate.files.attach(fixture_blob("certificate.pdf"))
    sign_in_as users(:admin)

    patch crew_member_certificate_path(@juan, certificate), params: { certificate: { notes: "Checked against the card", files: [ "" ] } }

    assert_redirected_to crew_member_certificate_path(@juan, certificate)
    assert_equal 1, certificate.reload.files.count
    assert_equal users(:admin), certificate.verified_by
  end

  test "update rejects a bad file and keeps the existing ones" do
    certificate = certificates(:juan_osha30)
    certificate.files.attach(fixture_blob("certificate.pdf"))
    sign_in_as users(:manager)

    patch crew_member_certificate_path(@juan, certificate), params: { certificate: { files: [ direct_upload("notes.txt") ] } }

    assert_response :unprocessable_entity
    assert_equal [ "certificate.pdf" ], certificate.reload.files.map { |file| file.filename.to_s }
  end

  test "update with a blank or unknown type re-renders the form named after the saved type" do
    certificate = certificates(:juan_osha30)
    sign_in_as users(:manager)

    [ "", "0" ].each do |type_id|
      patch crew_member_certificate_path(@juan, certificate), params: { certificate: { certificate_type_id: type_id } }

      assert_response :unprocessable_entity
      assert_select "title", text: /Edit OSHA 30 Construction/
      assert_select "h1", text: "Edit OSHA 30 Construction"
      assert_select "#error_explanation", text: /Certificate type must exist/
      assert_equal certificate_types(:osha30), certificate.reload.certificate_type
    end
  end

  test "moving the completed date forward makes a history entry current" do
    old = certificates(:juan_flagger_old)
    sign_in_as users(:manager)

    patch crew_member_certificate_path(@juan, old), params: { certificate: { completed_on: Date.current.iso8601, expires_on: "" } }

    assert old.reload.current?
    assert certificates(:juan_flagger).reload.superseded?
  end

  # --- remove_file ---

  test "an editor removes a single file" do
    certificate = certificates(:juan_osha30)
    certificate.files.attach(fixture_blob("certificate.pdf"), fixture_blob("certificate.jpg"))
    pdf = certificate.files.find { |file| file.filename.to_s == "certificate.pdf" }
    sign_in_as users(:manager)

    assert_enqueued_with(job: ActiveStorage::PurgeJob) do
      delete remove_file_crew_member_certificate_path(@juan, certificate), params: { attachment_id: pdf.id },
        headers: { "Referer" => edit_crew_member_certificate_url(@juan, certificate) }
    end

    assert_redirected_to edit_crew_member_certificate_url(@juan, certificate)
    assert_equal "Removed certificate.pdf.", flash[:notice]
    assert_equal [ "certificate.jpg" ], certificate.reload.files.map { |file| file.filename.to_s }
  end

  test "remove_file only touches the certificate's own files" do
    other = certificates(:juan_flagger)
    other.files.attach(fixture_blob("certificate.pdf"))
    sign_in_as users(:manager)

    delete remove_file_crew_member_certificate_path(@juan, certificates(:juan_osha30)), params: { attachment_id: other.files.first.id }

    assert_response :not_found
    assert_equal 1, other.reload.files.count
  end

  test "removing a file that was swapped for a smaller copy since the page loaded says so" do
    certificate = certificates(:juan_osha30)
    certificate.files.attach(fixture_blob("certificate.jpg"))
    stale = certificate.files_attachments.sole
    # What Certificates::ShrinkFilesJob does: a new attachment for the copy, the old one deleted.
    ActiveStorage::Attachment.create!(record: certificate, name: "files", blob: fixture_blob("certificate.png"))
    stale.delete
    sign_in_as users(:manager)

    assert_no_enqueued_jobs(only: ActiveStorage::PurgeJob) do
      delete remove_file_crew_member_certificate_path(@juan, certificate), params: { attachment_id: stale.id }
    end

    assert_redirected_to edit_crew_member_certificate_path(@juan, certificate)
    assert_equal 303, response.status
    assert_match "replaced by a smaller copy", flash[:alert]
    assert_equal [ "certificate.png" ], certificate.reload.files.map { |file| file.filename.to_s }
  end

  # --- destroy ---

  test "an admin deletes a certificate and the previous one becomes current" do
    sign_in_as users(:admin)

    assert_difference "Certificate.count", -1 do
      delete crew_member_certificate_path(@juan, certificates(:juan_flagger))
    end

    assert_redirected_to crew_member_path(@juan)
    assert certificates(:juan_flagger_old).reload.current?
  end

  test "a manager cannot delete a certificate" do
    sign_in_as users(:manager)

    assert_no_difference "Certificate.count" do
      delete crew_member_certificate_path(@juan, certificates(:juan_flagger))
    end
    assert_response :forbidden
  end

  # --- authorization ---

  test "viewer gets 403 on every write" do
    certificate = certificates(:juan_osha30)
    certificate.files.attach(fixture_blob("certificate.pdf"))
    sign_in_as users(:viewer)

    get new_crew_member_certificate_path(@juan)
    assert_response :forbidden
    get edit_crew_member_certificate_path(@juan, certificate)
    assert_response :forbidden

    assert_no_difference -> { Certificate.count } do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes }
    end
    assert_response :forbidden

    patch crew_member_certificate_path(@juan, certificate), params: { certificate: { notes: "nope", files: [ direct_upload("certificate.jpg") ] } }
    assert_response :forbidden
    assert_nil certificate.reload.notes
    assert_equal 1, certificate.files.count

    delete remove_file_crew_member_certificate_path(@juan, certificate), params: { attachment_id: certificate.files.first.id }
    assert_response :forbidden
    assert_equal 1, certificate.reload.files.count

    delete crew_member_certificate_path(@juan, certificate)
    assert_response :forbidden
    assert Certificate.exists?(certificate.id)
  end

  test "signed-out users are sent to sign in" do
    get crew_member_certificate_path(@juan, certificates(:juan_osha30))
    assert_redirected_to new_session_path
  end

  test "the crew member page renders compact file thumbnails" do
    certificates(:juan_osha30).files.attach(fixture_blob("certificate.jpg"), fixture_blob("certificate.pdf"))
    sign_in_as users(:viewer)

    get crew_member_path(@juan)

    assert_response :success
    assert_select "tr##{ActionView::RecordIdentifier.dom_id(certificates(:juan_osha30))} img", 2
  end

  # --- issuer and verification (Phase 3b) ---

  test "the form offers active issuers, Other... with a name field, and the verification fields" do
    summit = CertificateIssuer.create!(name: "Summit Safety Training", code: "SUMMIT", position: 1)
    retired = CertificateIssuer.create!(name: "Old Tower School", code: "OLDTOWER", active: false)
    sign_in_as users(:manager)

    get new_crew_member_certificate_path(@juan)

    assert_select "#verification_fields [data-controller=other-choice]" do
      assert_select "select[name=?][data-other-choice-target=select][data-action=?]", "certificate[certificate_issuer_id]",
        "change->other-choice#toggle" do
        assert_select "option[value='']", "Not known"
        assert_select "option[value=?]", summit.id.to_s, "Summit Safety Training"
        assert_select "option[value=?]", retired.id.to_s, count: 0
        assert_select "option[value=other]:not([selected])", "Other…"
      end
      assert_select "[data-other-choice-target=other] input[name=?][data-other-choice-target=name]", "certificate[other_issuer_name]"
    end
    assert_select "input[name=?]", "certificate[verification_code]"
    assert_select "input[name=?][inputmode=url]", "certificate[verification_url]"
    assert_select "input[name=?]", "certificate[issued_by]", count: 0 # only shown when there is a printed name
  end

  test "edit keeps an inactive issuer selected and shows the issuer as printed" do
    retired = CertificateIssuer.create!(name: "Old Tower School", code: "OLDTOWER", active: false)
    certificate = certificates(:juan_flagger)
    certificate.update!(certificate_issuer: retired, verification_code: "OT-77")
    sign_in_as users(:manager)

    get edit_crew_member_certificate_path(@juan, certificate)

    assert_select "select[name=?] option[value=?][selected]", "certificate[certificate_issuer_id]", retired.id.to_s, "Old Tower School (inactive)"
    assert_select "input[name=?][value=?]", "certificate[issued_by]", "ATSSA"
    assert_select "label[for=certificate_issued_by]", "Issuer as printed"
    assert_select "input[name=?][value=?]", "certificate[verification_code]", "OT-77"
  end

  test "create saves the issuer, code and link and queues a check" do
    summit = CertificateIssuer.create!(name: "Summit Safety Training", code: "SUMMIT")
    sign_in_as users(:manager)

    post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(
      certificate_issuer_id: summit.id, verification_code: " SUM-1001 ", verification_url: "verify.summitsafety.org/c/SUM-1001"
    ) }

    certificate = Certificate.order(:id).last
    assert_redirected_to crew_member_certificate_path(@juan, certificate)
    assert_equal summit, certificate.certificate_issuer
    assert_equal "SUM-1001", certificate.verification_code
    assert_equal "https://verify.summitsafety.org/c/SUM-1001", certificate.verification_url
    assert_enqueued_with(job: Verification::CheckJob, args: [ certificate ])
  end

  test "a new certificate without an issuer is checked once too" do
    sign_in_as users(:manager)

    post crew_member_certificates_path(@juan), params: { certificate: valid_attributes }

    assert_enqueued_with(job: Verification::CheckJob, args: [ Certificate.order(:id).last ])
  end

  test "Other... creates an issuer from the typed name" do
    sign_in_as users(:manager)

    assert_difference -> { CertificateIssuer.count } => 1, -> { Certificate.count } => 1 do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(
        certificate_issuer_id: "other", other_issuer_name: "  Granite  Peak Safety ") }
    end

    issuer = CertificateIssuer.find_by!(name: "Granite Peak Safety")
    assert issuer.verified_by_unknown?
    assert_empty issuer.domains
    assert_equal issuer, Certificate.order(:id).last.certificate_issuer
    assert_match(/Granite Peak Safety was added to the issuer list/, flash[:notice])
  end

  test "Other... with a name already on the list reuses that issuer" do
    summit = CertificateIssuer.create!(name: "Summit Safety Training", code: "SUMMIT")
    sign_in_as users(:manager)

    assert_no_difference -> { CertificateIssuer.count } do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(
        certificate_issuer_id: "other", other_issuer_name: "summit safety training") }
    end

    assert_equal summit, Certificate.order(:id).last.certificate_issuer
    assert_equal "Added Flagger for Juan Ortiz.", flash[:notice]
  end

  test "Other... with a name on the list as an alias, or an inactive issuer's name, reuses it and says so" do
    CertificateIssuer.seed_defaults!
    sign_in_as users(:manager)

    assert_no_difference -> { CertificateIssuer.count } do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(
        certificate_issuer_id: "other", other_issuer_name: "Red Cross") }
    end
    assert_equal "American Red Cross", Certificate.order(:id).last.certificate_issuer.name
    assert_equal "Added Flagger for Juan Ortiz. “Red Cross” is on the issuer list as American Red Cross, so that was used.", flash[:notice]

    retired = certificate_issuers(:retired_example)
    patch crew_member_certificate_path(@juan, Certificate.order(:id).last), params: { certificate: {
      certificate_issuer_id: "other", other_issuer_name: "retired example training co" } }
    assert_equal retired, Certificate.order(:id).last.certificate_issuer
    assert_match "Retired Example Training Co is on the issuer list but inactive; an admin can reactivate it.", flash[:notice]
  end

  test "without JavaScript a typed name with no issuer chosen counts as Other..." do
    sign_in_as users(:manager)

    assert_difference -> { CertificateIssuer.count }, 1 do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(
        certificate_issuer_id: "", other_issuer_name: "Granite Peak Safety") }
    end
    assert_equal "Granite Peak Safety", Certificate.order(:id).last.certificate_issuer.name
  end

  test "Other... without a name re-renders the form" do
    sign_in_as users(:manager)

    assert_no_difference [ "Certificate.count", "CertificateIssuer.count" ] do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(
        certificate_issuer_id: "other", other_issuer_name: " ") }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /Type the new issuer's name for Other…/
    assert_select "select[name=?] option[value=other][selected]", "certificate[certificate_issuer_id]"
    assert_no_enqueued_jobs only: Verification::CheckJob
  end

  test "a certificate that doesn't save leaves no new issuer, and the form keeps Other... and the name" do
    sign_in_as users(:manager)

    assert_no_difference [ "Certificate.count", "CertificateIssuer.count" ] do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(
        completed_on: (Date.current + 1).iso8601, certificate_issuer_id: "other", other_issuer_name: "Granite Peak Safety") }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /can't be in the future/
    assert_select "select[name=?] option[value=other][selected]", "certificate[certificate_issuer_id]"
    assert_select "select[name=?] option[value='']", "certificate[certificate_issuer_id]", count: 1 # no option for the rolled-back issuer
    assert_select "input[name=?][value=?]", "certificate[other_issuer_name]", "Granite Peak Safety"
  end

  test "an issuer that no longer exists and a link that isn't a web address are refused" do
    sign_in_as users(:manager)

    post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(
      certificate_issuer_id: "0", verification_url: "call the office") }

    assert_response :unprocessable_entity
    assert_select "#error_explanation" do
      assert_select "li", "That issuer is no longer on the list. Choose another."
      assert_select "li", /Verification link must be a web address/
    end
  end

  test "update queues a check only when the issuer, code, link, dates or files changed" do
    certificate = certificates(:juan_osha30)
    sign_in_as users(:manager)

    patch crew_member_certificate_path(@juan, certificate), params: { certificate: { notes: "Wallet card" } }
    assert_no_enqueued_jobs only: Verification::CheckJob

    patch crew_member_certificate_path(@juan, certificate), params: { certificate: { completed_on: (certificate.completed_on - 1).iso8601 } }
    assert_enqueued_with(job: Verification::CheckJob, args: [ certificate ]) # the checks compare the dates
    clear_enqueued_jobs

    patch crew_member_certificate_path(@juan, certificate), params: { certificate: { verification_code: "30-1234567" } }
    assert_enqueued_with(job: Verification::CheckJob, args: [ certificate ])
    clear_enqueued_jobs

    patch crew_member_certificate_path(@juan, certificate), params: { certificate: { verification_code: "30-1234567", notes: "Again" } }
    assert_no_enqueued_jobs only: Verification::CheckJob

    patch crew_member_certificate_path(@juan, certificate), params: { certificate: { certificate_issuer_id: "other", other_issuer_name: "Granite Peak Safety" } }
    assert_enqueued_with(job: Verification::CheckJob, args: [ certificate ])
    assert_equal "Granite Peak Safety", certificate.reload.certificate_issuer.name
    clear_enqueued_jobs

    # Added files: Certificates::ReadQrCodesJob reads their QR codes, then runs the check itself.
    patch crew_member_certificate_path(@juan, certificate), params: { certificate: { files: [ "", direct_upload("certificate.png") ] } }
    assert_no_enqueued_jobs only: Verification::CheckJob
    assert_enqueued_with(job: Certificates::ReadQrCodesJob)
    perform_enqueued_jobs(only: Certificates::ReadQrCodesJob)
    assert_enqueued_with(job: Verification::CheckJob, args: [ certificate ])
  end

  test "a new certificate with files is checked once, after its QR codes are read" do
    sign_in_as users(:manager)

    post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(files: [ "", direct_upload("certificate.png") ]) }

    certificate = Certificate.order(:id).last
    assert_no_enqueued_jobs only: Verification::CheckJob
    perform_enqueued_jobs(only: Certificates::ReadQrCodesJob)
    assert_enqueued_jobs 1, only: Verification::CheckJob
    assert_enqueued_with(job: Verification::CheckJob, args: [ certificate ])
  end

  test "show names the issuer and the name as printed" do
    summit = CertificateIssuer.create!(name: "Summit Safety Training", code: "SUMMIT")
    certificate = certificates(:juan_flagger)
    sign_in_as users(:viewer)

    get crew_member_certificate_path(@juan, certificate)
    assert_select "#certificate_issuer", "ATSSA"

    certificate.update!(certificate_issuer: summit)
    get crew_member_certificate_path(@juan, certificate)
    assert_select "#certificate_issuer", /Summit Safety Training\s+Printed as ATSSA/
    assert_select "#authenticity"
  end

  test "show says who entered or reviewed the details, keeping \"Verified\" for the issuer's check" do
    certificate = certificates(:juan_flagger)
    certificate.update!(verified_by: users(:manager), verified_at: Time.current)
    certificate.record_authenticity!(status: :not_found, method: "automatic:aha_ecards")
    sign_in_as users(:viewer)

    get crew_member_certificate_path(@juan, certificate)

    assert_select "dt", text: "Entered or reviewed by"
    assert_select "#certificate_reviewed_by", /Manny Manager/
    assert_select "dt", text: "Verified", count: 0
    assert_select "#authenticity_status", "Not found by issuer"

    certificate.update_columns(verified_by_id: nil, verified_at: nil, source: Certificate.sources[:import])
    get crew_member_certificate_path(@juan, certificate)
    assert_select "#certificate_reviewed_by", "No one: accepted automatically"
  end

  test "show's status keeps the dates' status for a certificate flagged for review, with a Review marker" do
    certificate = certificates(:juan_flagger)
    certificate.record_authenticity!(status: :mismatch, method: "automatic:qr_details360training")
    sign_in_as users(:viewer)

    get crew_member_certificate_path(@juan, certificate)

    assert_select "#certificate_status" do
      assert_select "[data-status=expiring]", text: "Expiring"
      assert_select "[data-authenticity-review=mismatch][title=?]",
        "Flagged for review: Doesn't match issuer. It still counts until someone checks it with the issuer.", text: /Review/
    end
    cell = css_select("#certificate_status").first
    assert_match(/Expiring\s+in \d+ days\s+Review/, cell.text.squish, "the days follow the status pill they describe")
  end

  test "show's status says confirmed fake, and why, once a person recorded it, with no days" do
    certificates(:juan_flagger_old).destroy!
    certificate = certificates(:juan_flagger) # expires in about 10 days
    certificate.record_authenticity!(status: :not_found, method: "manual", by: users(:manager))
    sign_in_as users(:viewer)

    get crew_member_certificate_path(@juan, certificate)

    assert certificate.reload.current?
    assert_select "#certificate_status" do
      assert_select "[data-status=fake][title=?]", "Confirmed fake: Not found by issuer", text: "Confirmed fake"
      assert_select "[data-authenticity-review]", count: 0
    end
    assert_no_match(/\d+ days?|ago/, css_select("#certificate_status").first.text, "not \"Confirmed fake in 10 days\"")

    certificate.update_columns(expires_on: Date.current - 3)
    get crew_member_certificate_path(@juan, certificate)
    assert_select "#certificate_status [data-status=fake]", text: "Confirmed fake"
    assert_no_match(/\d+ days?|ago/, css_select("#certificate_status").first.text)
  end

  test "show's status for a confirmed fake one kept as history behind a genuine one still says confirmed fake" do
    certificate = certificates(:juan_flagger)
    certificate.record_authenticity!(status: :mismatch, method: "person", by: users(:manager))
    sign_in_as users(:viewer)

    get crew_member_certificate_path(@juan, certificate)

    assert certificate.reload.superseded?
    assert_select "#certificate_status [data-status=fake]", text: "Confirmed fake"
    assert_select "#certificate_status", text: /Replaced/, count: 0
    assert_select "#superseded_notice", /Confirmed fake, so another Flagger certificate on file is the current one/
  end

  test "editing a confirmed fake certificate's verification code makes it need a check again, and says so" do
    certificates(:juan_flagger_old).destroy!
    certificate = certificates(:juan_flagger)
    certificate.update!(verification_code: "A128")
    certificate.record_authenticity!(status: :not_found, method: "person", by: users(:manager))
    sign_in_as users(:manager)

    patch crew_member_certificate_path(@juan, certificate), params: { certificate: { verification_code: "A12B" } }

    assert_redirected_to crew_member_certificate_path(@juan, certificate)
    assert_includes flash[:notice], "A person recorded “Not found by issuer”, but the verification code changed afterwards, " \
      "so it is no longer confirmed fake. Check it with the issuer again."
    certificate.reload
    assert_equal [ "needs_check", "details_changed" ], [ certificate.authenticity_status, certificate.authenticity_method ]
    assert_equal "expiring", certificate.compliance_status
    assert_enqueued_with job: Verification::CheckJob, args: [ certificate ]
  end

  test "clearing a confirmed fake certificate's code: the queued check leaves it needing a person's check, saying why" do
    certificates(:juan_flagger_old).destroy!
    certificate = certificates(:juan_flagger)
    certificate.update!(verification_code: "A128")
    certificate.record_authenticity!(status: :not_found, method: "person", note: "Issuer has no such card", by: users(:manager))
    sign_in_as users(:manager)

    patch crew_member_certificate_path(@juan, certificate), params: { certificate: { verification_code: "" } }
    perform_enqueued_jobs(only: Verification::CheckJob)

    certificate.reload
    assert_equal [ "needs_check", "details_changed" ], [ certificate.authenticity_status, certificate.authenticity_method ],
      "the rules alone (nothing to check with) don't settle what a person found"
    assert_match(/\AA person recorded “Not found by issuer”, but the verification code changed afterwards/, certificate.authenticity_note)
    assert_equal [ "not_found", "Issuer has no such card" ], certificate.authenticity_details.values_at("previous_status", "previous_note")
    assert_equal 1, Certificate.where(id: certificate.id).authenticity_review_counts["needs_check"]
  end

  test "editing a confirmed fake certificate's notes keeps it confirmed fake" do
    certificate = certificates(:juan_flagger)
    certificate.record_authenticity!(status: :not_found, method: "person", by: users(:manager))
    sign_in_as users(:manager)

    patch crew_member_certificate_path(@juan, certificate), params: { certificate: { notes: "Asked Juan for the real card." } }

    assert certificate.reload.authenticity_confirmed_fake?
    assert_match(/It is confirmed fake, so another Flagger certificate on file is the current one and this one is kept as history\./,
      flash[:notice])
  end

  test "show's status for a verified certificate has no Review marker" do
    certificate = certificates(:juan_flagger)
    certificate.record_authenticity!(status: :verified, method: "automatic:aha_ecards")
    sign_in_as users(:viewer)

    get crew_member_certificate_path(@juan, certificate)

    assert_select "#certificate_status [data-status=expiring]"
    assert_select "#certificate_status [data-authenticity-review]", count: 0
  end

  private
    def no_expiration_certificate
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(no_expiration: "1") }
      @juan.certificates.order(:id).last
    end

    def valid_attributes
      { certificate_type_id: @flagger.id, certificate_number: "FL-90001", issued_by: "ATSSA",
        completed_on: Date.current.iso8601, expires_on: "", notes: "" }
    end

    def fixture_blob(name)
      ActiveStorage::Blob.create_and_upload!(io: file_fixture(name).open, filename: name)
    end

    # What the browser does: create the blob first, PUT the bytes, then submit the signed id.
    # The declared content type is the browser's guess; the server re-identifies on attach.
    def direct_upload(name, content_type: nil)
      direct_upload_data(file_fixture(name).binread, filename: name, content_type: content_type)
    end

    def direct_upload_data(data, filename:, content_type: nil)
      blob = ActiveStorage::Blob.create_before_direct_upload!(
        filename: filename, byte_size: data.bytesize, checksum: OpenSSL::Digest::MD5.base64digest(data), content_type: content_type
      )
      blob.service.upload(blob.key, StringIO.new(data))
      blob.signed_id
    end
end
