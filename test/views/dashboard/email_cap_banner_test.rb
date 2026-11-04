require "test_helper"

class DashboardEmailCapBannerTest < ActionView::TestCase
  setup { travel_to Time.zone.local(2026, 11, 2, 9, 0) }

  test "renders nothing when no sends were deferred" do
    EmailSendDay.create!(day: Date.current, sent_count: 40)

    assert_equal "", render(partial: "dashboard/email_cap_banner").strip
  end

  test "renders an amber banner for sends deferred today" do
    EmailSendDay.create!(day: Date.current, sent_count: 90, deferred_count: 3)

    render partial: "dashboard/email_cap_banner"

    assert_select "#email_cap_banner.bg-amber-50[role=status]" do
      assert_select "p", text: "Daily email limit reached"
      assert_select "p", text: /3 emails were held back today/
      assert_select "p", text: /90-a-day sending limit/
      assert_select "p", text: /\(90 sent\)/
      assert_select "p", text: /Expiry alerts go out on the next daily run; weekly digests are retried the next morning;\s+import summaries go out the next morning at 7:00 Denver time\./
    end
  end

  test "mentions yesterday's deferrals" do
    EmailSendDay.create!(day: Date.yesterday, sent_count: 90, deferred_count: 1)

    render partial: "dashboard/email_cap_banner"

    assert_select "#email_cap_banner p", text: /1 email was held back yesterday/
  end

  test "older deferrals no longer show" do
    EmailSendDay.create!(day: Date.current - 2, sent_count: 90, deferred_count: 12)

    assert_equal "", render(partial: "dashboard/email_cap_banner").strip
  end
end
