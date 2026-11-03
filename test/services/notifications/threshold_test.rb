require "test_helper"

class Notifications::ThresholdTest < ActiveSupport::TestCase
  test "ALL runs least to most urgent" do
    assert_equal %w[d90 d60 d30 d7 expired], Notifications::Threshold::ALL
    assert_equal Notifications::Threshold::ALL, Notifications::Threshold::ALL.sort_by { |t| Notifications::Threshold.urgency(t) }
  end

  test "for_days_left picks the most urgent crossed threshold" do
    {
      91 => nil, 90 => "d90", 61 => "d90", 60 => "d60", 31 => "d60", 30 => "d30", 8 => "d30",
      7 => "d7", 0 => "d7", -1 => "expired", -400 => "expired", nil => nil
    }.each do |days_left, expected|
      actual = Notifications::Threshold.for_days_left(days_left)
      expected ? assert_equal(expected, actual, "days_left #{days_left}") : assert_nil(actual, "days_left #{days_left.inspect}")
    end
  end

  test "covered? is true when the same or a more urgent threshold was sent" do
    assert Notifications::Threshold.covered?("d30", "d30")
    assert Notifications::Threshold.covered?("d30", "d7")
    assert Notifications::Threshold.covered?(:d90, "expired")
    assert_not Notifications::Threshold.covered?("d7", "d30")
    assert_not Notifications::Threshold.covered?("expired", "d7")
    assert_not Notifications::Threshold.covered?("d90", nil)
  end

  test "most_urgent" do
    assert_equal "d7", Notifications::Threshold.most_urgent(%w[d90 d7 d30])
    assert_equal "expired", Notifications::Threshold.most_urgent([ "expired", nil, "d60" ])
    assert_nil Notifications::Threshold.most_urgent([])
  end

  test "crew members are only emailed at d30 and d7" do
    assert_equal %w[d30 d7], Notifications::Threshold::ALL.select { |t| Notifications::Threshold.crew?(t) }
  end

  test "label" do
    assert_equal "90 days", Notifications::Threshold.label("d90")
    assert_equal "7 days", Notifications::Threshold.label(:d7)
    assert_equal "Expired", Notifications::Threshold.label("expired")
  end
end
