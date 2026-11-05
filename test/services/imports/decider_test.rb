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
      "expiry before completion" => item(proposed_expires_on: Date.current - 20),
      "flagged for review" => item(authenticity_status: :suspicious)
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

  test "a flagged authenticity check is named; one that needs a person or can't be done doesn't block" do
    Authenticity::FLAGGED_STATUSES.each do |status|
      reasons = Imports::Config.with(auto_accept_enabled: true) { Imports::Decider.new(item(authenticity_status: status)).reasons }
      assert_equal [ "Flagged for review: #{Authenticity::LABELS.fetch(status).downcase_first}" ], reasons
    end
    assert_equal "Flagged for review: suspicious link",
      Imports::Config.with(auto_accept_enabled: true) { Imports::Decider.new(item(authenticity_status: :suspicious)).reasons.sole }

    %i[unchecked needs_check verified cannot_verify].each do |status|
      assert_equal :accept, decide(item(authenticity_status: status)), status
    end
  end

  test "a flag only for review blocks auto-accept, whatever found it; a person's not found is named as fake" do
    %w[automatic:national_cpr_foundation qr_details:qr_details_360training qr_link verification_link].each do |method|
      record = item(authenticity_status: :mismatch, authenticity_method: method)
      assert_equal :review, decide(record), method
      assert_equal [ "Flagged for review: doesn't match issuer" ],
        Imports::Config.with(auto_accept_enabled: true) { Imports::Decider.new(record).reasons }
    end

    fake = item(authenticity_status: :not_found, authenticity_method: "person")
    assert_equal :review, decide(fake)
    assert_equal [ "Confirmed fake: not found by issuer" ], Imports::Config.with(auto_accept_enabled: true) { Imports::Decider.new(fake).reasons }
  end

  test "an issuer check still waiting for the issuer's site keeps it for review" do
    Imports::Config.with(auto_accept_enabled: true) do
      decider = Imports::Decider.new(item(authenticity_status: :needs_check), issuer_check_pending: true)

      assert_equal :review, decider.call
      assert_equal [ "The issuer's site hasn't been asked yet" ], decider.reasons
    end
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
