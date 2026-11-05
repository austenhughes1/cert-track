require "test_helper"

class Verification::DateTextTest < ActiveSupport::TestCase
  def parse(text)
    Verification::DateText.parse(text)
  end

  test "full dates in the formats issuers print" do
    march_14 = Date.new(2025, 3, 14)
    [ "2025-03-14", "03/14/2025", "3/14/2025", "03-14-2025", "March 14, 2025", "Mar 14, 2025", "March 14 2025",
      "14 March 2025", "14 Mar 2025", " 03/14/2025. " ].each do |text|
      date = parse(text)
      assert_equal march_14, date&.date, text
      assert_not date.month_only, text
    end
  end

  test "month-only dates (an AHA renewal month)" do
    [ "03/2027", "3/2027", "2027-03", "March 2027", "Mar 2027" ].each do |text|
      date = parse(text)
      assert_equal Date.new(2027, 3, 1), date&.date, text
      assert date.month_only, text
    end
  end

  test "anything else is nil" do
    [ nil, "", "soon", "13/14/2025", "02/30/2025", "03/14/25", "2025-03-14 and more", "Active" ].each do |text|
      assert_nil parse(text), text.inspect
    end
  end

  test "compare: a full date within a day matches" do
    completed = Date.new(2025, 3, 14)

    assert_equal "match", Verification::DateText.compare(completed, "03/14/2025")
    assert_equal "match", Verification::DateText.compare(completed, "2025-03-15")
    assert_equal "match", Verification::DateText.compare(completed, "2025-03-13")
    assert_equal "differs", Verification::DateText.compare(completed, "2025-03-16")
    assert_equal "differs", Verification::DateText.compare(completed, "03/14/2024")
  end

  test "compare: a month-only date, or month_only: true, matches the same month" do
    expires = Date.new(2027, 3, 31)

    assert_equal "match", Verification::DateText.compare(expires, "03/2027")
    assert_equal "differs", Verification::DateText.compare(expires, "04/2027")
    assert_equal "match", Verification::DateText.compare(expires, "03/02/2027", month_only: true)
    assert_equal "differs", Verification::DateText.compare(expires, "03/02/2027")
  end

  test "compare: nil when either side is missing or unreadable" do
    assert_nil Verification::DateText.compare(nil, "03/14/2025")
    assert_nil Verification::DateText.compare(Date.new(2025, 3, 14), nil)
    assert_nil Verification::DateText.compare(Date.new(2025, 3, 14), "n/a")
  end
end
