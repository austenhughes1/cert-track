require "test_helper"

# Import files are editors-only until accepted, like the import and review pages that link to
# them, and the signed links on pages expire (config/initializers/active_storage_auth.rb,
# active_storage.rb; docs/PLAN.md, "Security and privacy").
class ImportFileAccessTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @item = import_items(:review_juan_first_aid)
    @item.file.attach(io: file_fixture("certificate.jpg").open, filename: "scan.jpg", content_type: "image/jpeg")
    @blob = @item.file.blob
  end

  test "a viewer gets 403 for an import item's file, through every Active Storage route" do
    sign_in_as users(:viewer)

    get rails_blob_path(@blob, disposition: "inline")
    assert_response :forbidden
    get rails_storage_proxy_path(@blob)
    assert_response :forbidden
    assert_no_difference -> { ActiveStorage::VariantRecord.count } do
      get url_for(@item.file.variant(resize_to_limit: [ 160, 160 ]))
      assert_response :forbidden
      get rails_storage_proxy_path(@item.file.variant(resize_to_limit: [ 160, 160 ]))
      assert_response :forbidden
    end
  end

  test "a viewer gets 403 for a batch's raw upload" do
    batch = import_batches(:march_batch)
    batch.uploads.attach(io: StringIO.new("PK zip"), filename: "crew.zip", content_type: "application/zip")
    sign_in_as users(:viewer)

    get rails_blob_path(batch.uploads.sole, disposition: "attachment")

    assert_response :forbidden
  end

  test "editors get import files" do
    [ users(:manager), users(:admin) ].each do |user|
      sign_in_as user

      get rails_blob_path(@blob, disposition: "inline")
      assert_response :redirect
      follow_redirect!
      assert_response :success
      assert_equal file_fixture("certificate.jpg").binread, response.body
      sign_out
    end
  end

  test "once accepted, the certificate shares the blob and viewers can open it like any certificate file" do
    certificates(:juan_osha30).files.attach(@blob)
    sign_in_as users(:viewer)

    get rails_blob_path(@blob, disposition: "inline")

    assert_response :redirect
  end

  test "a blob attached to nothing is editors-only" do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("card"), filename: "card.pdf", content_type: "application/pdf")

    sign_in_as users(:viewer)
    get rails_blob_path(blob, disposition: "inline")
    assert_response :forbidden
    sign_out

    sign_in_as users(:manager)
    get rails_blob_path(blob, disposition: "inline")
    assert_response :redirect
  end

  test "a variant's own blob is judged by the import file it was made from" do
    variant = @item.file.variant(resize_to_limit: [ 160, 160 ]).processed
    variant_blob = variant.image.blob

    sign_in_as users(:viewer)
    get rails_blob_path(variant_blob, disposition: "inline")
    assert_response :forbidden
  end

  test "a demoted manager loses access to links copied while an editor" do
    manager = users(:manager)
    sign_in_as manager
    get rails_blob_path(@blob, disposition: "inline")
    assert_response :redirect
    link = rails_blob_path(@blob, disposition: "inline")

    manager.update!(role: :viewer)
    get link

    assert_response :forbidden
  end

  test "signed links on pages expire after an hour" do
    assert_equal 1.hour, ActiveStorage.urls_expire_in
    sign_in_as users(:manager)
    link = rails_blob_path(@blob, disposition: "inline")

    travel 59.minutes do
      get link
      assert_response :redirect
    end
    travel 61.minutes do
      get link
      assert_response :not_found
    end
  end
end
