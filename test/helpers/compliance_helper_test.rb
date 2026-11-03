require "test_helper"

class ComplianceHelperTest < ActionView::TestCase
  Cell = Compliance::ProjectReport::Cell

  def cell(status, expires_on = nil)
    Cell.new(certificate_type: certificate_types(:flagger), status: status, certificate: nil, expires_on: expires_on)
  end

  def badge(...)
    Nokogiri::HTML5.fragment(compliance_badge(...)).at_css("span")
  end

  test "status_label" do
    assert_equal "Valid", status_label("valid")
    assert_equal "Expiring", status_label(:expiring)
    assert_equal "Lapses on project", status_label("lapses_on_project")
    assert_equal "Expired", status_label("expired")
    assert_equal "Missing", status_label("missing")
    assert_equal "Not required", status_label("not_required")
    assert_equal "Something else", status_label("something_else")
  end

  test "format_date" do
    assert_equal "Mar 14, 2025", format_date(Date.new(2025, 3, 14))
    assert_equal "Mar 4, 2025", format_date(Date.new(2025, 3, 4))
    assert_equal "Mar 4, 2025", format_date(Time.zone.local(2025, 3, 4, 15))
    assert_equal "—", format_date(nil)
  end

  test "a cell badge shows the expiry date and the status" do
    span = badge(cell("expiring", Date.new(2025, 3, 14)))

    assert_equal "Expiring, Mar 14, 2025", span.text
    assert_equal "Expiring: expires Mar 14, 2025", span["title"]
    assert_equal "expiring", span["data-status"]
    assert_includes span["class"], "bg-amber-100"
    assert_equal "Expiring, ", span.at_css(".sr-only").text
  end

  test "expired badges say expired" do
    span = badge("expired", Date.new(2025, 1, 2))

    assert_equal "Expired: expired Jan 2, 2025", span["title"]
    assert_includes span["class"], "bg-red-600"
  end

  test "badge colours by status" do
    assert_includes badge("valid")["class"], "bg-green-100"
    assert_includes badge("lapses_on_project", Date.new(2025, 1, 2))["class"], "bg-orange-100"
    assert_includes badge("missing")["class"], "ring-red-500"
    assert_includes badge(:not_required)["class"], "text-gray-400"
  end

  test "badges without a date show the label" do
    assert_equal "Missing", badge(cell("missing")).text
    assert_equal "Missing", badge(cell("missing"))["title"]
    assert_equal "Valid", badge("valid").text
    assert_equal "Valid: never expires", badge(cell("valid"))["title"]
  end

  test "not_required is a grey dash" do
    span = badge(cell("not_required"))

    assert_equal "—", span.text
    assert_equal "Not required", span["title"]
  end

  test "an explicit date wins over the cell's" do
    assert_includes badge(cell("valid", Date.new(2027, 1, 1)), Date.new(2028, 2, 2)).text, "Feb 2, 2028"
  end

  test "badge output is escaped" do
    assert_not_includes compliance_badge("<script>"), "<script>"
  end
end
