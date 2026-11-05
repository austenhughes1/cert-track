require "test_helper"

class Verification::ConfigTest < ActiveSupport::TestCase
  def with_env(value)
    previous = ENV["VERIFICATION_AUTO_CHECKS"]
    ENV["VERIFICATION_AUTO_CHECKS"] = value
    yield
  ensure
    ENV["VERIFICATION_AUTO_CHECKS"] = previous
  end

  test "automatic checks are off in tests, even when the variable says true" do
    with_env("true") { assert_not Verification::Config.auto_checks? }
    with_env(nil) { assert_not Verification::Config.auto_checks? }
  end

  test "outside tests they default to on, and only false turns them off" do
    assert Verification::Config.auto_checks_value(nil)
    assert Verification::Config.auto_checks_value("true")
    assert Verification::Config.auto_checks_value("")
    assert Verification::Config.auto_checks_value("0"), "only false turns them off"
    assert_not Verification::Config.auto_checks_value("false")
    assert_not Verification::Config.auto_checks_value(" FALSE ")
  end

  test "with overrides for the block only, and restores after an error" do
    Verification::Config.with(auto_checks: true) do
      assert Verification::Config.auto_checks?
      Verification::Config.with(auto_checks: false) { assert_not Verification::Config.auto_checks? }
      assert Verification::Config.auto_checks?
    end
    assert_not Verification::Config.auto_checks?

    assert_raises(RuntimeError) { Verification::Config.with(auto_checks: true) { raise "boom" } }
    assert_not Verification::Config.auto_checks?
  end

  test "the overrides are local to the thread" do
    Verification::Config.with(auto_checks: true) do
      assert_not Thread.new { Verification::Config.auto_checks? }.value
    end
  end

  test "the request limits PLAN.md fixes, overridable for tests" do
    assert_equal 10, Verification::Config.http_timeout
    assert_equal 1.megabyte, Verification::Config.max_response_bytes
    assert_equal 5, Verification::Config.min_request_interval
    assert_equal 200, Verification::Config.daily_requests_per_host
    assert_equal "CertTrack certificate verification (+https://certs.abaventures.net)", Verification::Config.user_agent

    Verification::Config.with(daily_requests_per_host: 2) { assert_equal 2, Verification::Config.daily_requests_per_host }
  end

  test "unknown settings are refused" do
    assert_raises(ArgumentError) { Verification::Config.with(auto_check: true) { flunk } }
  end
end
