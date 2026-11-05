require "test_helper"

class ComplianceHelperTest < ActionView::TestCase
  Cell = Compliance::ProjectReport::Cell

  def cell(status, expires_on = nil)
    Cell.new(certificate_type: certificate_types(:flagger), status: status, certificate: nil, expires_on: expires_on)
  end

  def badge(...)
    Nokogiri::HTML5.fragment(compliance_badge(...)).at_css("span")
  end

  def review_marker(html)
    Nokogiri::HTML5.fragment(html.to_s).at_css("[data-authenticity-review]")
  end

  test "status_label" do
    assert_equal "Valid", status_label("valid")
    assert_equal "Expiring", status_label(:expiring)
    assert_equal "Lapses on project", status_label("lapses_on_project")
    assert_equal "Expired", status_label("expired")
    assert_equal "Missing", status_label("missing")
    assert_equal "Confirmed fake", status_label("fake")
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

  test "fake badges say confirmed fake instead of a date, with why when the certificate is known" do
    certificate = certificates(:juan_flagger)
    certificate.assign_attributes(authenticity_status: "not_found", authenticity_method: "person")
    fake = Cell.new(certificate_type: certificate.certificate_type, status: "fake", certificate: certificate,
      expires_on: certificate.expires_on)

    span = badge(fake)
    assert_equal "Confirmed fake", span.text
    assert_equal "Confirmed fake: Not found by issuer", span["title"]
    assert_equal "fake", span["data-status"]
    assert_includes span["class"], "bg-red-800"
    assert_nil review_marker(compliance_badge(fake)), "a confirmed fake certificate isn't also marked for review"

    assert_equal "Confirmed fake", badge("fake", Date.new(2027, 1, 1)).text
    assert_equal "Confirmed fake", badge("fake")["title"]
    assert_equal "Confirmed fake: Doesn't match issuer",
      badge("fake", certificate: Certificate.new(authenticity_status: "mismatch", authenticity_method: "person"))["title"]
    assert_equal "Confirmed fake", status_label("fake")
  end

  test "a certificate only flagged for review keeps its date badge and gets a Review marker" do
    certificate = certificates(:juan_flagger)
    certificate.assign_attributes(authenticity_status: "mismatch", authenticity_method: "automatic:aha_ecards")
    expiring = Cell.new(certificate_type: certificate.certificate_type, status: "expiring", certificate: certificate,
      expires_on: certificate.expires_on)

    html = compliance_badge(expiring)
    assert_equal "expiring", badge(expiring)["data-status"]
    assert_includes badge(expiring).text, format_date(certificate.expires_on)

    marker = review_marker(html)
    assert_equal "mismatch", marker["data-authenticity-review"]
    assert_equal "Flagged for review: Doesn't match issuer. It still counts until someone checks it with the issuer.", marker["title"]
    assert_equal "Review", marker.at_css("[aria-hidden=true]").text
    assert_equal "Flagged for review", marker.at_css(".sr-only").text
    assert_includes marker["class"], "ring-red-600"
    assert_not_includes marker.text, "fake"

    # The certificate: keyword works for bare statuses too (crew page, gaps list, certificate page).
    assert review_marker(compliance_badge("valid", certificate: certificate))
    assert review_marker(compliance_badge("expired", Date.new(2025, 1, 2), certificate: certificate))
  end

  test "flagged_for_review_marker is only for flagged certificates a person hasn't confirmed fake" do
    marker = ->(status, method = nil) { flagged_for_review_marker(Certificate.new(authenticity_status: status, authenticity_method: method)) }

    %w[not_found mismatch suspicious].each do |status|
      assert marker.(status), "#{status} from an automatic check"
      assert marker.(status, nil), "#{status} with no method recorded"
    end
    assert_nil marker.("not_found", "person")
    assert_nil marker.("mismatch", "person")
    # A person can't record suspicious (no such button), but one set that way still isn't fake.
    assert marker.("suspicious", "person")
    %w[unchecked needs_check verified cannot_verify].each { |status| assert_nil marker.(status, "person") }
    assert_nil marker.("verified", "automatic:aha_ecards")
    assert_nil flagged_for_review_marker(nil)
    assert_includes Nokogiri::HTML5.fragment(marker.("suspicious")).at_css("span")["title"], "Suspicious link"
  end

  test "badges without a known certificate never get a Review marker" do
    assert_nil review_marker(compliance_badge("valid"))
    assert_nil review_marker(compliance_badge(cell("missing")))
    assert_nil review_marker(compliance_badge(cell("not_required")))
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
