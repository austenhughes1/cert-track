require "test_helper"

# Certificate files are personal data: every Active Storage endpoint needs a session,
# only editors may start uploads, and service URLs are short-lived (docs/PLAN.md, Security).
class FileAccessTest < ActionDispatch::IntegrationTest
  setup do
    @certificate = certificates(:juan_osha30)
    @pdf = attach("certificate.pdf")
    @jpeg = attach("certificate.jpg")
  end

  test "anonymous requests for a file are sent to sign in" do
    get rails_blob_path(@pdf, disposition: "attachment")
    assert_redirected_to new_session_path

    get rails_storage_proxy_path(@pdf)
    assert_redirected_to new_session_path
  end

  test "anonymous thumbnail requests are sent to sign in before anything is processed" do
    assert_no_difference -> { ActiveStorage::VariantRecord.count } do
      get url_for(@jpeg.variant(resize_to_limit: [ 160, 160 ]))
      assert_redirected_to new_session_path

      get rails_storage_proxy_path(@jpeg.variant(resize_to_limit: [ 160, 160 ]))
      assert_redirected_to new_session_path
    end
    assert_nil @pdf.blob.reload.preview_image.attachment

    get url_for(@pdf.preview(resize_to_limit: [ 160, 160 ]))
    assert_redirected_to new_session_path
    assert_not @pdf.blob.reload.preview_image.attached?
  end

  test "a service URL stops working once the session is gone" do
    sign_in_as users(:viewer)
    get rails_blob_path(@pdf, disposition: "inline")
    service_url = response.location
    sign_out

    get service_url
    assert_redirected_to new_session_path
  end

  test "a signed-in viewer can view and download files through a short-lived redirect" do
    sign_in_as users(:viewer)

    get rails_blob_path(@pdf, disposition: "inline")
    assert_response :redirect
    assert_match %r{/rails/active_storage/disk/}, response.location
    assert_includes response.headers["Cache-Control"], "max-age=300"
    assert_includes response.headers["Cache-Control"], "private"
    follow_redirect!
    assert_response :success
    assert_equal file_fixture("certificate.pdf").binread, response.body

    get rails_blob_path(@jpeg, disposition: "attachment")
    follow_redirect!
    assert_response :success
    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
  end

  test "a signed-in viewer gets image thumbnails and PDF previews" do
    sign_in_as users(:viewer)

    get url_for(@jpeg.variant(resize_to_limit: [ 160, 160 ]))
    assert_response :redirect
    follow_redirect!
    assert_response :success
    assert_equal "image/jpeg", response.media_type

    skip "pdftoppm is not installed; PDF previews not tested" unless ActiveStorage::Previewer::PopplerPDFPreviewer.pdftoppm_exists?
    get url_for(@pdf.preview(resize_to_limit: [ 160, 160 ]))
    assert_response :redirect
    follow_redirect!
    assert_response :success
    assert_equal "image/png", response.media_type
  end

  test "proxied files are never marked cacheable by shared caches" do
    sign_in_as users(:viewer)

    [ rails_storage_proxy_path(@pdf), rails_storage_proxy_path(@jpeg.variant(resize_to_limit: [ 160, 160 ])) ].each do |path|
      get path

      assert_response :success
      assert_includes response.headers["Cache-Control"], "private"
      assert_not_includes response.headers["Cache-Control"], "public"
    end
  end

  test "a viewer cannot start a direct upload" do
    sign_in_as users(:viewer)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      post rails_direct_uploads_path, as: :json, params: { blob: blob_params }
    end
    assert_response :forbidden
  end

  test "editors can start a direct upload" do
    [ users(:manager), users(:admin) ].each do |user|
      sign_in_as user

      assert_difference -> { ActiveStorage::Blob.count }, 1 do
        post rails_direct_uploads_path, as: :json, params: { blob: blob_params }
      end
      assert_response :success
      assert response.parsed_body["signed_id"].present?
      sign_out
    end
  end

  test "anonymous direct uploads are sent to sign in" do
    assert_no_difference -> { ActiveStorage::Blob.count } do
      post rails_direct_uploads_path, as: :json, params: { blob: blob_params }
    end
    assert_redirected_to new_session_path
  end

  private
    def attach(name)
      blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture(name).open, filename: name)
      ActiveStorage::Attachment.create!(record: @certificate, name: "files", blob: blob)
    end

    def blob_params
      { filename: "card.pdf", byte_size: 4, checksum: Digest::MD5.base64digest("card"), content_type: "application/pdf" }
    end
end
