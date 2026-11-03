require "test_helper"

class Imports::DeciderTest < ActiveSupport::TestCase
  # Passes every auto-accept rule (when auto-accept is on).
  def item(**overrides)
    ImportItem.new({
      import_batch: import_batches(:march_batch), sha256: "d" * 64, status: :extracting,
      matched_certificate_type: certificate_types(:flagger), type_match: :matched,
      matched_crew_member: crew_members(:juan_ortiz), person_match: :matched,
      proposed_completed_on: Date.current - 10, proposed_expires_on: Date.current + 1000,
      proposed_expires_on_source: :computed, confidence: 0.85
    }.merge(overrides))
  end

  def decide(record)
    Imports::Config.with(auto_accept_enabled: true) { Imports::Decider.new(record).call }
  end

  test "accepts when every rule holds and auto-accept is on" do
    assert_equal :accept, decide(item)
    assert_empty Imports::Config.with(auto_accept_enabled: true) { Imports::Decider.new(item).reasons }
  end

  test "auto-accept off (the default) always reviews" do
    assert_not Imports::Config.auto_accept_enabled?
    assert_equal :review, Imports::Decider.new(item).call
    assert_equal [ "Auto-accept is turned off" ], Imports::Decider.new(item).reasons

    assert_equal :review, Imports::Config.with(auto_accept_enabled: false) { Imports::Decider.new(item).call }
  end

  test "AUTO_ACCEPT_ENABLED=true in the environment turns it on" do
    previous = ENV["AUTO_ACCEPT_ENABLED"]
    ENV["AUTO_ACCEPT_ENABLED"] = "true"
    assert_equal :accept, Imports::Decider.new(item).call
  ensure
    previous.nil? ? ENV.delete("AUTO_ACCEPT_ENABLED") : ENV["AUTO_ACCEPT_ENABLED"] = previous
  end

  test "each failing rule sends the item to review" do
    {
      "type only suggested" => item(type_match: :suggested),
      "type unmatched" => item(type_match: :unmatched, matched_certificate_type: nil),
      "matched type now inactive" => item(matched_certificate_type: certificate_types(:retired_hazwoper)),
      "person only suggested" => item(person_match: :suggested),
      "person unmatched" => item(person_match: :unmatched, matched_crew_member: nil),
      "matched person inactive" => item(matched_crew_member: crew_members(:sam_inactive)),
      "no completion date" => item(proposed_completed_on: nil),
      "no expiry and the type expires" => item(proposed_expires_on: nil, proposed_expires_on_source: nil),
      "confidence below 0.85" => item(confidence: 0.84),
      "no confidence" => item(confidence: nil),
      "date problems noted" => item(error_message: "The completion date 2027-01-01 is in the future."),
      "completion date in the future" => item(proposed_completed_on: Date.current + 1),
      "expiry before completion" => item(proposed_expires_on: Date.current - 20)
    }.each do |label, record|
      assert_equal :review, decide(record), label
      assert_equal 1, Imports::Config.with(auto_accept_enabled: true) { Imports::Decider.new(record).reasons.size }, label
    end
  end

  test "no expiry is fine when the type never expires" do
    record = item(matched_certificate_type: certificate_types(:osha30), proposed_expires_on: nil, proposed_expires_on_source: :none)

    assert_equal :accept, decide(record)
  end

  test "a printed expiry is enough for a type without validity" do
    record = item(matched_certificate_type: certificate_types(:cdl_a), proposed_expires_on: Date.current + 400, proposed_expires_on_source: :printed)

    assert_equal :accept, decide(record)
  end

  test "the confidence threshold comes from Imports::Config" do
    Imports::Config.with(auto_accept_enabled: true, auto_accept_confidence: 0.9) do
      assert_equal :review, Imports::Decider.new(item(confidence: 0.89)).call
      assert_equal :accept, Imports::Decider.new(item(confidence: 0.9)).call
    end
  end

  test "lists every reason at once" do
    reasons = Imports::Decider.new(ImportItem.new(error_message: "The completion date is in the future.")).reasons

    assert_equal 7, reasons.size
  end
end
