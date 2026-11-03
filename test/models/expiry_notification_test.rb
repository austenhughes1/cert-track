require "test_helper"

class ExpiryNotificationTest < ActiveSupport::TestCase
  test "thresholds are ordered least to most urgent" do
    assert_equal({ "d90" => 0, "d60" => 1, "d30" => 2, "d7" => 3, "expired" => 4 }, ExpiryNotification.thresholds)
  end

  test "each certificate, threshold and recipient is logged once" do
    duplicate = ExpiryNotification.new(certificate: certificates(:juan_flagger), threshold: :d30, recipient_email: " Manager@Example.com ")
    assert_not duplicate.valid?
    assert_equal "manager@example.com", duplicate.recipient_email

    assert_raises(ActiveRecord::RecordNotUnique) do
      ExpiryNotification.transaction(requires_new: true) do
        ExpiryNotification.insert_all!([ { certificate_id: certificates(:juan_flagger).id, threshold: 2, recipient_email: "MANAGER@example.com" } ])
      end
    end
    assert ExpiryNotification.create!(certificate: certificates(:juan_flagger), threshold: :d7, recipient_email: "manager@example.com")
  end

  test "requires certificate, threshold and recipient" do
    notification = ExpiryNotification.new
    assert_not notification.valid?
    assert notification.errors[:certificate].any?
    assert notification.errors[:threshold].any?
    assert notification.errors[:recipient_email].any?
  end

  test "sent and unsent scopes" do
    pending = ExpiryNotification.create!(certificate: certificates(:dave_cdl_a), threshold: :d30, recipient_email: "admin@example.com")
    assert_equal [ pending ], ExpiryNotification.unsent.to_a
    assert_equal 2, ExpiryNotification.sent.count
  end

  test "threshold_for picks the most urgent crossed threshold" do
    assert_nil ExpiryNotification.threshold_for(91)
    assert_nil ExpiryNotification.threshold_for(nil)
    assert_equal "d90", ExpiryNotification.threshold_for(90)
    assert_equal "d90", ExpiryNotification.threshold_for(61)
    assert_equal "d60", ExpiryNotification.threshold_for(60)
    assert_equal "d30", ExpiryNotification.threshold_for(30)
    assert_equal "d30", ExpiryNotification.threshold_for(8)
    assert_equal "d7", ExpiryNotification.threshold_for(7)
    assert_equal "d7", ExpiryNotification.threshold_for(0)
    assert_equal "expired", ExpiryNotification.threshold_for(-1)
  end
end
