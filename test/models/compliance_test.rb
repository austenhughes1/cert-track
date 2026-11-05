require "test_helper"

class ComplianceTest < ActiveSupport::TestCase
  setup { @today = Date.new(2026, 11, 2) }

  def status(expires_on, project_ends_on: nil)
    Compliance.status_for(Certificate.new(expires_on: expires_on), today: @today, project_ends_on: project_ends_on)
  end

  test "missing without a certificate" do
    assert_equal "missing", Compliance.status_for(nil, today: @today)
  end

  test "valid when the certificate never expires" do
    assert_equal "valid", status(nil, project_ends_on: @today + 365)
  end

  test "expired when expires_on is before today" do
    assert_equal "expired", status(@today - 1)
  end

  test "expiring from today through the 30-day window" do
    assert_equal "expiring", status(@today)
    assert_equal "expiring", status(@today + 30)
    assert_equal "valid", status(@today + 31)
  end

  test "expiring wins over lapses_on_project" do
    assert_equal "expiring", status(@today + 10, project_ends_on: @today + 100)
  end

  test "lapses_on_project when it expires before the project ends" do
    assert_equal "lapses_on_project", status(@today + 60, project_ends_on: @today + 61)
    assert_equal "valid", status(@today + 60, project_ends_on: @today + 60)
    assert_equal "valid", status(@today + 60)
  end

  test "status_for_expiry works from a bare date" do
    assert_equal "expired", Compliance.status_for_expiry(@today - 3, today: @today)
    assert_equal "valid", Compliance.status_for_expiry(nil, today: @today)
  end

  # A certificate with an authenticity result. by_person: recorded with the panel's buttons
  # (method "person"), else by an automatic check.
  def checked(authenticity, by_person:, expires_on: nil)
    method = by_person ? Authenticity::PERSON_METHOD : "automatic:aha_ecards"
    Certificate.new(expires_on: expires_on, authenticity_status: authenticity, authenticity_method: method)
  end

  test "fake when a person recorded not found or doesn't match, whatever its dates" do
    Authenticity::FAKE_STATUSES.each do |authenticity|
      [ nil, @today - 3, @today + 10, @today + 400 ].each do |expires_on|
        certificate = checked(authenticity, by_person: true, expires_on: expires_on)
        assert_equal "fake", Compliance.status_for(certificate, today: @today, project_ends_on: @today + 500)
      end
    end
  end

  test "flagged only for review keeps the status its dates give it (never omit a certificate unless it is verified fake)" do
    Authenticity::FLAGGED_STATUSES.each do |authenticity|
      [ "automatic:aha_ecards", "qr_details:qr_details_360training", "qr_link", "verification_link", nil ].each do |method|
        certificate = ->(expires_on) { Certificate.new(expires_on:, authenticity_status: authenticity, authenticity_method: method) }
        assert_equal "valid", Compliance.status_for(certificate.(nil), today: @today), "#{authenticity} by #{method.inspect}"
        assert_equal "expired", Compliance.status_for(certificate.(@today - 3), today: @today)
        assert_equal "expiring", Compliance.status_for(certificate.(@today + 10), today: @today)
        assert_equal "lapses_on_project", Compliance.status_for(certificate.(@today + 400), today: @today, project_ends_on: @today + 500)
      end
    end
  end

  test "a suspicious link is never fake, even with a person's method" do
    # The panel can't record suspicious (Authenticity::PERSON_STATUSES), but a stray row must still count.
    assert_not_includes Authenticity::PERSON_STATUSES, "suspicious"
    assert_equal "valid", Compliance.status_for(checked("suspicious", by_person: true), today: @today)
    assert_equal "expired", Compliance.status_for(checked("suspicious", by_person: true, expires_on: @today - 1), today: @today)
  end

  test "checks that didn't flag it leave the expiry status alone, whoever recorded them" do
    %w[unchecked needs_check verified cannot_verify].each do |authenticity|
      [ true, false ].each do |by_person|
        assert_equal "valid", Compliance.status_for(checked(authenticity, by_person:), today: @today)
        assert_equal "expired", Compliance.status_for(checked(authenticity, by_person:, expires_on: @today - 1), today: @today)
      end
    end
  end

  test "status_for_expiry is the date rule alone: a confirmed fake certificate needs status_for" do
    assert_equal "lapses_on_project", Compliance.status_for_expiry(@today + 60, today: @today, project_ends_on: @today + 61)
    assert_raises(ArgumentError) { Compliance.status_for_expiry(nil, today: @today, authenticity_status: "mismatch") }
  end

  test "defaults today to Denver's date" do
    travel_to Time.utc(2026, 11, 3, 3, 0) do # still Nov 2 in Denver
      assert_equal "expiring", Compliance.status_for(Certificate.new(expires_on: Date.new(2026, 11, 2)))
    end
  end

  test "worst picks the most severe status" do
    assert_equal "fake", Compliance.worst(%w[valid missing expired fake expiring])
    assert_equal "expired", Compliance.worst(%w[valid missing expired expiring])
    assert_equal "missing", Compliance.worst(%i[valid missing lapses_on_project])
    assert_equal "lapses_on_project", Compliance.worst(%w[valid lapses_on_project])
    assert_equal "valid", Compliance.worst(%w[valid])
    assert_nil Compliance.worst([])
  end

  test "constants and labels" do
    assert_equal %w[missing fake expired expiring lapses_on_project valid], Compliance::STATUSES
    assert_equal Compliance::STATUSES.sort, Compliance::SEVERITY.sort
    assert_equal %w[fake expired missing expiring lapses_on_project valid], Compliance::SEVERITY
    assert_equal 30, Compliance::EXPIRING_WINDOW
    assert_equal "Lapses on project", Compliance.label(:lapses_on_project)
    assert_equal "Confirmed fake", Compliance.label("fake")
    assert_not_includes Compliance::STATUSES, "flagged", "flagged for review is not a compliance status"
    assert_equal Compliance::STATUSES.sort, Compliance::LABELS.keys.sort
  end

  test "fixture dataset covers every status on tower_2417" do
    project = projects(:tower_2417)
    statuses = project.project_assignments.includes(:crew_member).to_h do |assignment|
      member = assignment.crew_member
      cells = assignment.required_certificate_types.to_h do |type|
        [ type.code, member.current_certificate_for(type)&.compliance_status(project_ends_on: project.ends_on) || "missing" ]
      end
      [ member.first_name, cells ]
    end

    assert_equal({ "OSHA30" => "valid", "FLAGGER" => "expiring", "FIRSTAID" => "lapses_on_project", "CLIMBER" => "valid" }, statuses["Juan"])
    assert_equal({ "OSHA30" => "valid", "FLAGGER" => "missing", "FIRSTAID" => "expired" }, statuses["Maria"])
    assert_equal({ "OSHA30" => "valid", "FLAGGER" => "valid", "FIRSTAID" => "expired", "CLIMBER" => "missing" }, statuses["Li"])
    assert_equal({ "OSHA30" => "valid", "FLAGGER" => "valid", "FIRSTAID" => "missing", "CDLA" => "expiring" }, statuses["David"])
  end
end
