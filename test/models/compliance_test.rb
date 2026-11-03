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

  test "defaults today to Denver's date" do
    travel_to Time.utc(2026, 11, 3, 3, 0) do # still Nov 2 in Denver
      assert_equal "expiring", Compliance.status_for(Certificate.new(expires_on: Date.new(2026, 11, 2)))
    end
  end

  test "worst picks the most severe status" do
    assert_equal "expired", Compliance.worst(%w[valid missing expired expiring])
    assert_equal "missing", Compliance.worst(%i[valid missing lapses_on_project])
    assert_equal "lapses_on_project", Compliance.worst(%w[valid lapses_on_project])
    assert_equal "valid", Compliance.worst(%w[valid])
    assert_nil Compliance.worst([])
  end

  test "constants and labels" do
    assert_equal %w[missing expired expiring lapses_on_project valid], Compliance::STATUSES
    assert_equal Compliance::STATUSES.sort, Compliance::SEVERITY.sort
    assert_equal 30, Compliance::EXPIRING_WINDOW
    assert_equal "Lapses on project", Compliance.label(:lapses_on_project)
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
