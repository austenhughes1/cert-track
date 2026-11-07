require "test_helper"
require_relative "match_test_support"

class Imports::AcceptAllTest < ActiveSupport::TestCase
  include ImportsMatchTestSupport
  include ActiveJob::TestHelper

  def ready(**attrs)
    review_item(type: certificate_types(:flagger), confidence: 0.85, proposed_expires_on: Date.current + 300, proposed_expires_on_source: :printed, proposed_certificate_number: "N-#{SecureRandom.hex(3)}", bytes: SecureRandom.hex(8), **attrs)
  end

  test "accepts what is ready, at 85% confidence or more, and leaves the rest" do
    good = ready
    unsure = ready(confidence: 0.84)
    flagged = ready(quality_flags: [ "qr_unreadable" ])
    suspicious = ready(authenticity_status: :suspicious, authenticity_method: "qr_link")
    no_date = ready(proposed_completed_on: nil)
    suggested = ready(person_match: :suggested)

    result = Imports::AcceptAll.new(user: users(:manager)).call

    assert_equal 1, result.accepted
    assert good.reload.accepted?
    [ unsure, flagged, suspicious, no_date, suggested ].each { |item| assert item.reload.needs_review?, item.inspect }
  end

  test "works with auto-accept off, which it isn't" do
    item = ready
    Imports::Config.with(auto_accept_enabled: false) do
      assert_empty Imports::AcceptAll.blockers(item)
      assert_includes Imports::Decider.new(item).reasons, "Auto-accept is turned off"
    end
  end

  test "the two sides of a card wait for a person to merge them" do
    number = "SAME-1"
    front = ready(proposed_certificate_number: number)
    back = ready(proposed_certificate_number: number)

    assert_includes Imports::AcceptAll.blockers(front), Imports::AcceptAll::MERGE_REASON
    assert_equal 0, Imports::AcceptAll.new(user: users(:manager)).call.accepted
    assert back.reload.needs_review?
  end

  test "one refused item doesn't stop the others" do
    good = ready
    bad = ready
    original = Imports::Accept.method(:new)
    Imports::Accept.define_singleton_method(:new) do |item, **options|
      raise ActiveRecord::RecordInvalid.new(item) if item.id == bad.id

      original.call(item, **options)
    end
    begin
      result = Imports::AcceptAll.new(user: users(:manager)).call
    ensure
      Imports::Accept.define_singleton_method(:new, original)
    end

    assert_equal [ 1, 1 ], [ result.accepted, result.skipped ]
    assert good.reload.accepted?
  end
end
