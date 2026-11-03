require "test_helper"

class CertificatesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @juan = crew_members(:juan_ortiz)
    @flagger = certificate_types(:flagger)
  end

  # --- show / new ---

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

  test "a HEIC upload queues the JPEG conversion" do
    sign_in_as users(:manager)

    assert_enqueued_with(job: Certificates::ConvertHeicJob) do
      post crew_member_certificates_path(@juan), params: { certificate: valid_attributes.merge(files: [ direct_upload("certificate.heic") ]) }
    end
    assert_equal "image/heic", Certificate.order(:id).last.files.first.content_type
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
    sign_in_as users(:manager)

    patch crew_member_certificate_path(@juan, certificate), params: { certificate: {
      issued_by: "OSHA Training Institute", files: [ "", direct_upload("certificate.jpg"), direct_upload("certificate.png") ]
    } }

    assert_redirected_to crew_member_certificate_path(@juan, certificate)
    certificate.reload
    assert_equal %w[certificate.jpg certificate.pdf certificate.png], certificate.files.map { |file| file.filename.to_s }.sort
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

  private
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
