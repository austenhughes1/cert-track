require "test_helper"

class VerificationControllerTest < ActionDispatch::IntegrationTest
  setup do
    @issuer = CertificateIssuer.create!(name: "Summit Safety Training", code: "SUMMIT")
    # Confirmed fake: a person's not_found or mismatch.
    @mismatch = certificates(:li_flagger)
    @mismatch.record_authenticity!(status: :mismatch, method: "person", note: "Different name on the issuer's page", by: users(:manager))
    @not_found = certificates(:juan_climber)
    @not_found.record_authenticity!(status: :not_found, method: "person", by: users(:admin))
    # Flagged for review: an automatic check's or a QR code's.
    @suspicious = certificates(:juan_flagger)
    @suspicious.update!(certificate_issuer: @issuer)
    @suspicious.record_authenticity!(status: :suspicious, method: "rules", note: "The QR code points to a lookalike website.")
    @auto_mismatch = certificates(:maria_osha30)
    @auto_mismatch.record_authenticity!(status: :mismatch, method: "automatic:aha_ecards", note: "The issuer shows a different name.")
    @auto_not_found = certificates(:juan_first_aid)
    @auto_not_found.record_authenticity!(status: :not_found, method: "automatic:aha_ecards")
    @needs_check = certificates(:dave_flagger)
    @needs_check.record_authenticity!(status: :needs_check, method: "rules", note: "Look the code up on the issuer's page.")
    certificates(:juan_flagger_old).record_authenticity!(status: :not_found, method: "person", by: users(:admin)) # superseded
    certificates(:sam_flagger).record_authenticity!(status: :not_found, method: "rules") # inactive member
    certificates(:sam_osha30).record_authenticity!(status: :mismatch, method: "person", by: users(:admin)) # inactive member
    certificates(:juan_osha30).record_authenticity!(status: :verified, method: "rules")
  end

  test "requires sign-in" do
    get verification_path
    assert_redirected_to new_session_path
  end

  test "every role sees the list, worst first, with person, type, issuer, status, note and a link" do
    %i[viewer manager admin].each do |role|
      sign_in_as users(role)

      get verification_path

      assert_response :success, role
      assert_select "title", "Verification · CertTrack"
      sign_out
    end
    sign_in_as users(:viewer)

    get verification_path

    rows = css_select("#verification_certificates tbody tr").map { it["id"] }
    assert_equal [ @mismatch, @not_found, @suspicious, @auto_mismatch, @auto_not_found, @needs_check ].map { dom_id(it, :verification) }, rows,
      "confirmed fake first, then flagged for review (suspicious, mismatch, not found), then needs a check"
    assert_select "tr##{dom_id(@suspicious, :verification)}" do
      assert_select "a[href=?]", crew_member_path(crew_members(:juan_ortiz)), "Juan Ortiz"
      assert_select "td", "Flagger"
      assert_select "td[data-column=issuer]", "Summit Safety Training"
      assert_select "td[data-column=status] [data-authenticity=suspicious][title=?]", "Flagged for review: Suspicious link", "Suspicious link"
      assert_select "td[data-column=note]", /lookalike website/
      assert_select "td[data-column=checked]", /Checked automatically/
      assert_select "a[href=?]", crew_member_certificate_path(crew_members(:juan_ortiz), @suspicious, anchor: "authenticity"), "Open"
    end
    assert_select "tr##{dom_id(@mismatch, :verification)} td[data-column=issuer]", @mismatch.issued_by # the name as printed
    assert_select "tr##{dom_id(@mismatch, :verification)} td[data-column=checked]", /Checked by Manny Manager/
    assert_select "tr##{dom_id(@mismatch, :verification)} td[data-column=status]" do
      assert_select "[data-authenticity=mismatch][data-fake=true].bg-red-800[title=?]", "Confirmed fake: Doesn't match issuer", "Confirmed fake"
      assert_select "p", "Doesn't match issuer"
    end
    assert_select "tr##{dom_id(@auto_mismatch, :verification)} td[data-column=status]" do
      assert_select "[data-authenticity=mismatch][data-fake]", count: 0
      assert_select "[data-authenticity=mismatch].bg-red-600[title=?]", "Flagged for review: Doesn't match issuer", "Doesn't match issuer"
    end
    assert_select "nav a[aria-current=page]", /All\s+6/
  end

  test "filters to confirmed fake, flagged for review or needs a check" do
    sign_in_as users(:viewer)

    get verification_path(status: "fake")
    assert_equal [ @mismatch, @not_found ].map { dom_id(it, :verification) }, listed
    assert_select "nav a[aria-current=page]", /Confirmed fake\s+2/

    get verification_path(status: "flagged")
    assert_equal [ @suspicious, @auto_mismatch, @auto_not_found ].map { dom_id(it, :verification) }, listed
    assert_select "nav a[aria-current=page]", /Flagged for review\s+3/

    get verification_path(status: "needs_check")
    assert_equal [ dom_id(@needs_check, :verification) ], listed
    assert_select "nav a", /Needs a check\s+1/

    get verification_path(status: "bogus")
    assert_select "#verification_certificates tbody tr", 6
  end

  test "a suspicious one recorded as a person's, or a flag with no method, is only flagged for review" do
    # A person can't record suspicious (Authenticity::PERSON_STATUSES), but a row could still say so.
    certificates(:maria_first_aid).update_columns(authenticity_status: Certificate.authenticity_statuses[:suspicious],
      authenticity_method: "person")
    certificates(:dave_osha30).update_columns(authenticity_status: Certificate.authenticity_statuses[:not_found], authenticity_method: nil)
    sign_in_as users(:viewer)

    get verification_path(status: "flagged")
    assert_equal [ certificates(:maria_first_aid), @suspicious, @auto_mismatch, certificates(:dave_osha30), @auto_not_found ]
      .map { dom_id(it, :verification) }, listed
    assert_select "[data-fake]", count: 0

    get verification_path
    assert_equal [ @mismatch, @not_found ].map { dom_id(it, :verification) }, listed.first(2)
    assert_select "nav a", /Confirmed fake\s+2/
    assert_select "nav a", /Flagged for review\s+5/
  end

  test "empty states" do
    Certificate.update_all(authenticity_status: Certificate.authenticity_statuses[:verified])
    sign_in_as users(:viewer)

    { "fake" => "No certificates are confirmed fake", "flagged" => "No certificates are flagged for review",
      "needs_check" => "No certificates need a check", nil => "Nothing to check" }.each do |status, message|
      get verification_path(status: status)

      assert_select "#verification_certificates", count: 0
      assert_select "#verification_empty p:first-child", message
    end
  end

  test "the filters are Authenticity's" do
    assert_equal Authenticity::REVIEW_FILTERS, VerificationController::FILTERS.keys
  end

  test "query count does not grow with the list" do
    sign_in_as users(:viewer)
    get verification_path # warm up
    baseline = count_queries { get verification_path }

    issuer = CertificateIssuer.create!(name: "Ridgeline CPR", code: "RIDGE")
    3.times do |index|
      member = CrewMember.create!(first_name: "Extra", last_name: "Hand #{index}", crew_role: crew_roles(:operator))
      %i[flagger first_aid].each do |type|
        certificate = member.certificates.create!(certificate_type: certificate_types(type), completed_on: Date.current - 30,
          expires_on: Date.current + 40, certificate_issuer: issuer)
        certificate.record_authenticity!(status: type == :flagger ? :not_found : :mismatch, method: "person", by: users(:manager))
      end
    end

    assert_equal baseline, count_queries { get verification_path }
    assert_select "#verification_certificates tbody tr", 12
  end

  test "notes are escaped" do
    @needs_check.update_columns(authenticity_note: "<script>alert(1)</script>")
    sign_in_as users(:viewer)

    get verification_path

    assert_no_match(/<script>alert/, response.body)
  end

  private
    def listed
      css_select("#verification_certificates tbody tr").map { it["id"] }
    end

    # Integration requests share the test's pinned connection, whose query cache
    # survives between requests until a write, so clear it to count real queries.
    def count_queries(&block)
      ActiveRecord::Base.connection_pool.clear_query_cache
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:cached] || payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
end
