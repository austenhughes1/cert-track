require "test_helper"

# The review form posts to Accept, and its "Save edits" and Merge buttons send the same fields
# to other URLs (formaction). Per-form CSRF tokens are on, so the form has to carry a token
# that every one of those URLs accepts: without Turbo (or before it loads) the browser sends
# only the form's own hidden authenticity_token, never the X-CSRF-Token header.
class ImportReviewCsrfTest < ActionDispatch::IntegrationTest
  setup do
    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    @item = import_items(:review_juan_first_aid)
    @juan = crew_members(:juan_ortiz)
    @first_aid = certificate_types(:first_aid)
    @item.update!(matched_crew_member: @juan, person_match: :matched, proposed_certificate_number: "FA-77001")
    sign_in_as users(:manager)
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_protection
  end

  test "Save edits goes through with the form's own token" do
    token = review_form_token

    post import_review_path(@item), params: { _method: "patch", authenticity_token: token, review: review_params(certificate_number: "FA-1") }

    assert_redirected_to import_review_path(@item)
    assert_equal "FA-1", @item.reload.proposed_certificate_number
  end

  test "Merge goes through with the form's own token" do
    back = ImportItem.create!(import_batch: @item.import_batch, status: :needs_review, sha256: SecureRandom.hex(32),
      original_filename: "back.jpg", matched_crew_member: @juan, person_match: :matched, matched_certificate_type: @first_aid,
      type_match: :matched, proposed_certificate_number: "FA-77001")
    token = review_form_token
    assert_select "#merge_button"

    assert_difference -> { Certificate.count }, 1 do
      post merge_import_review_path(@item), params: { authenticity_token: token, review: review_params, other_ids: [ back.id ] }
    end
    assert_redirected_to import_reviews_path
    assert back.reload.accepted?
  end

  test "Accept goes through with the form's own token" do
    token = review_form_token

    assert_difference -> { Certificate.count }, 1 do
      post accept_import_review_path(@item), params: { authenticity_token: token, review: review_params }
    end
    assert @item.reload.accepted?
  end

  test "a missing or forged token is still refused" do
    review_form_token

    patch import_review_path(@item), params: { review: review_params(certificate_number: "FA-1") }
    assert_response :unprocessable_entity
    post import_review_path(@item), params: { _method: "patch", authenticity_token: "forged", review: review_params(certificate_number: "FA-1") }
    assert_response :unprocessable_entity
    assert_equal "FA-77001", @item.reload.proposed_certificate_number
  end

  private
    # The hidden token in the rendered review form, as a browser would submit it.
    def review_form_token
      get import_review_path(@item)
      assert_response :success
      css_select("form#review_form input[type=hidden][name=authenticity_token]").sole["value"].presence || flunk("no token")
    end

    def review_params(**overrides)
      { crew_member_id: @juan.id, certificate_type_id: @first_aid.id, completed_on: @item.proposed_completed_on.iso8601,
        expires_on: "", certificate_number: "FA-77001", issued_by: "" }.merge(overrides)
    end
end
