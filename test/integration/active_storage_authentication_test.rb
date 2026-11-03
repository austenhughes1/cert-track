require "test_helper"

class ActiveStorageAuthenticationTest < ActionDispatch::IntegrationTest
  setup do
    @blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("card"), filename: "card.pdf", content_type: "application/pdf"
    )
  end

  test "blob redirect requires sign-in" do
    get rails_blob_path(@blob, disposition: "inline")
    assert_redirected_to new_session_path
  end

  test "representation redirect requires sign-in" do
    get rails_blob_representation_path(@blob.signed_id, "variation", @blob.filename)
    assert_redirected_to new_session_path
  end

  test "direct upload requires sign-in" do
    assert_no_difference "ActiveStorage::Blob.count" do
      post rails_direct_uploads_path, as: :json, params: {
        blob: { filename: "card.pdf", byte_size: 4, checksum: Digest::MD5.base64digest("card"), content_type: "application/pdf" }
      }
    end
    assert_redirected_to new_session_path
  end

  test "signed-in users get a service URL that expires within 5 minutes" do
    certificates(:juan_osha30).files.attach(@blob) # a blob attached to nothing is editors-only
    sign_in_as users(:viewer)

    get rails_blob_path(@blob, disposition: "inline")
    assert_response :redirect
    assert_match %r{/rails/active_storage/disk/}, response.location

    follow_redirect!
    assert_response :success
    assert_equal "card", response.body

    assert_equal 5.minutes, ActiveStorage.service_urls_expire_in
  end

  test "signed-in users can create a direct upload" do
    sign_in_as users(:manager)

    post rails_direct_uploads_path, as: :json, params: {
      blob: { filename: "card.pdf", byte_size: 4, checksum: Digest::MD5.base64digest("card"), content_type: "application/pdf" }
    }
    assert_response :success
    assert response.parsed_body.dig("direct_upload", "url").present?
  end
end
