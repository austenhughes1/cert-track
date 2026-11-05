require "test_helper"

class Imports::DateRulesTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 11, 3)

  def rules(completed_on:, expires_on: nil, type: certificate_types(:flagger), today: TODAY)
    Imports::DateRules.new(completed_on:, expires_on:, certificate_type: type, today:).call
  end

  test "a printed expiry is kept as printed" do
    result = rules(completed_on: "2025-03-14", expires_on: "2027-03-14")

    assert_equal Date.new(2025, 3, 14), result.completed_on
    assert_equal Date.new(2027, 3, 14), result.expires_on
    assert_equal :printed, result.expires_on_source
    assert_empty result.errors
    assert_not result.errors?
  end

  test "a printed expiry wins even when the type never expires" do
    result = rules(completed_on: "2024-01-10", expires_on: "2029-01-10", type: certificate_types(:cdl_a))

    assert_equal Date.new(2029, 1, 10), result.expires_on
    assert_equal :printed, result.expires_on_source
  end

  test "no printed expiry and a type with validity -> computed" do
    result = rules(completed_on: "2025-03-14") # flagger: 36 months

    assert_equal Date.new(2028, 3, 14), result.expires_on
    assert_equal :computed, result.expires_on_source
    assert_empty result.errors
  end

  test "no printed expiry and a type that never expires -> none" do
    result = rules(completed_on: "2025-03-14", type: certificate_types(:osha30))

    assert_nil result.expires_on
    assert_equal :none, result.expires_on_source
  end

  test "no type yet means the 2-year default, which the reviewer's choice of type replaces" do
    result = rules(completed_on: "2025-03-14", type: nil)

    assert_equal Date.new(2027, 3, 14), result.expires_on
    assert_equal :computed, result.expires_on_source
    assert_empty result.errors
  end

  test "a validity period printed on the card beats the type's" do
    result = Imports::DateRules.new(completed_on: "2025-03-14", expires_on: nil, validity_months: 12,
      certificate_type: certificate_types(:flagger), today: TODAY).call

    assert_equal Date.new(2026, 3, 14), result.expires_on
    assert_equal :printed_period, result.expires_on_source
  end

  test "a printed date beats a printed period" do
    result = Imports::DateRules.new(completed_on: "2025-03-14", expires_on: "2025-09-01", validity_months: 12,
      certificate_type: certificate_types(:flagger), today: TODAY).call

    assert_equal [ Date.new(2025, 9, 1), :printed ], [ result.expires_on, result.expires_on_source ]
  end

  test "a type that never expires ignores a reported period" do
    type = CertificateType.new(name: "OSHA 10", code: "OSHA10", validity_months: nil)
    result = Imports::DateRules.new(completed_on: "2025-03-14", expires_on: nil, validity_months: 12, certificate_type: type, today: TODAY).call

    assert_equal [ nil, :none ], [ result.expires_on, result.expires_on_source ]
  end

  test "a certificate that says no expiration has none, whatever its type's validity" do
    result = Imports::DateRules.new(completed_on: "2025-03-14", expires_on: nil, no_expiration: true,
      certificate_type: certificate_types(:flagger), today: TODAY).call

    assert_equal [ nil, :no_expiration ], [ result.expires_on, result.expires_on_source ]
  end

  test "a printed date beats no_expiration, and an unreadable one isn't replaced by it" do
    printed = Imports::DateRules.new(completed_on: "2025-03-14", expires_on: "2027-03-14", no_expiration: true, certificate_type: nil, today: TODAY).call
    unreadable = Imports::DateRules.new(completed_on: "2025-03-14", expires_on: "06/2027", no_expiration: true, certificate_type: nil, today: TODAY).call

    assert_equal :printed, printed.expires_on_source
    assert_nil unreadable.expires_on_source
  end

  test "no completion date means nothing to compute from" do
    result = rules(completed_on: nil)

    assert_nil result.completed_on
    assert_nil result.expires_on
    assert_nil result.expires_on_source
    assert_empty result.errors
  end

  test "a completion date in the future is an error but is kept for the reviewer" do
    result = rules(completed_on: "2026-11-04")

    assert_equal Date.new(2026, 11, 4), result.completed_on
    assert_equal [ "The completion date 2026-11-04 is in the future." ], result.errors
    assert_equal :computed, result.expires_on_source
  end

  test "today is not in the future" do
    assert_empty rules(completed_on: "2026-11-03").errors
  end

  test "an expiry before the completion date is an error" do
    result = rules(completed_on: "2025-03-14", expires_on: "2025-03-13")

    assert_equal Date.new(2025, 3, 13), result.expires_on
    assert_equal [ "The expiration date 2025-03-13 is before the completion date 2025-03-14." ], result.errors
  end

  test "an expiry on the completion date is allowed" do
    assert_empty rules(completed_on: "2025-03-14", expires_on: "2025-03-14").errors
  end

  test "malformed dates become nil with an error" do
    [ "03/14/2025", "2025-02-30", "2025-13-01", "March 14, 2025", "2025-03-14T10:00:00Z", "20250314", "unknown" ].each do |bad|
      result = rules(completed_on: bad)

      assert_nil result.completed_on, bad
      assert_equal [ "The completion date \"#{bad}\" is not a valid YYYY-MM-DD date." ], result.errors, bad
    end
  end

  test "an unreadable printed expiry is not replaced by a computed one" do
    result = rules(completed_on: "2025-03-14", expires_on: "14/03/2027")

    assert_nil result.expires_on
    assert_nil result.expires_on_source
    assert_equal [ "The expiration date \"14/03/2027\" is not a valid YYYY-MM-DD date." ], result.errors
  end

  test "blank strings count as absent, whitespace and single-digit parts are tolerated" do
    result = rules(completed_on: " 2025-3-4 ", expires_on: "  ")

    assert_equal Date.new(2025, 3, 4), result.completed_on
    assert_equal :computed, result.expires_on_source
    assert_empty result.errors
  end

  test "accepts Date objects and defaults today to Date.current" do
    result = Imports::DateRules.new(completed_on: Date.current + 1, expires_on: nil, certificate_type: nil).call

    assert_equal Date.current + 1, result.completed_on
    assert_equal 1, result.errors.size
  end

  test "both rules can fail at once" do
    result = rules(completed_on: "2027-01-01", expires_on: "2026-12-01")

    assert_equal 2, result.errors.size
  end
end
