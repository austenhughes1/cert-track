require "test_helper"

class Imports::Eval::ScorerTest < ActiveSupport::TestCase
  test "one person's several certificates on a page are paired by their names" do
    entry = ->(name, code) { { "pages" => [ 1 ], "holder_name" => "Juan Ortiz", "certificate_name_as_printed" => name, "certificate_type_code" => code } }
    score = Imports::Eval::Scorer.new(expected: { "certificates" => [ entry.call("First Aid", "FIRSTAID"), entry.call("Flagger", "FLAGGER") ] },
      actual: { "certificates" => [ entry.call("Flagger", "FLAGGER"), entry.call("First Aid", "FIRSTAID") ] }).call

    assert_equal [ 2, 2 ], score.fields.fetch("certificate_type_code")
  end

  test "the printed name allows small differences in wording, not another certificate" do
    score = ->(want, got) {
      Imports::Eval::Scorer.new(expected: { "certificates" => [ { "pages" => [ 1 ], "certificate_name_as_printed" => want } ] },
        actual: { "certificates" => [ { "pages" => [ 1 ], "certificate_name_as_printed" => got } ] }).call.fields.fetch("certificate_name_as_printed")
    }

    assert_equal [ 1, 1 ], score.call("Adult First Aid/CPR/AED", "ADULT FIRST AID / CPR / AED")
    assert_equal [ 1, 1 ], score.call("Bloodborne Pathogens Online Training", "Bloodborne Pathogens Training Online Course")
    assert_equal [ 0, 1 ], score.call("Bloodborne Pathogens Online Training", "Hazard Communication Online Training")
    assert_equal [ 0, 0 ], score.call(nil, "Anything")
  end

  test "a perfect answer scores every field" do
    score = score(expected: [ card ], actual: [ card ])

    assert_equal [ 1, 1 ], score.fields["certificate_type_code"]
    assert(Imports::Eval::Scorer::FIELDS.all? { |field| score.correct?(field) })
    assert_equal [ 1, 0, 0 ], [ score.matched, score.missing, score.extra ]
    assert_empty score.mismatches
  end

  test "holder names compare after NameNormalizer, codes ignore case, numbers ignore punctuation" do
    actual = card("holder_name" => "ORTIZ, JUAN A.", "certificate_type_code" => "osha30", "certificate_number" => "30 1234567")

    score = score(expected: [ card ], actual: [ actual ])

    assert score.correct?("holder_name")
    assert score.correct?("certificate_type_code")
    assert score.correct?("certificate_number")
  end

  test "dates must match exactly, and null only matches null" do
    score = score(expected: [ card("expires_on" => nil) ], actual: [ card("completed_on" => "2025-03-15", "expires_on" => "2028-03-14") ])

    assert_not score.correct?("completed_on")
    assert_not score.correct?("expires_on")
    assert_equal [ "completed_on", "expires_on" ], score.mismatches.map { |mismatch| mismatch["field"] }
    assert_equal({ "field" => "expires_on", "expected" => nil, "actual" => "2028-03-14" }, score.mismatches.last)
  end

  test "certificates pair by shared pages, whatever order the model returns them in" do
    li = card("pages" => [ 3 ], "holder_name" => "Li Chen", "certificate_type_code" => "FLAGGER")

    score = score(expected: [ card, li ], actual: [ li, card ])

    assert_equal [ 2, 2 ], score.fields["holder_name"]
    assert_equal [ 2, 2 ], score.fields["certificate_type_code"]
  end

  test "a missing certificate scores its fields wrong; an extra one is counted" do
    li = card("pages" => [ 3 ], "holder_name" => "Li Chen")

    missing = score(expected: [ card, li ], actual: [ card ])
    assert_equal [ 1, 2 ], missing.fields["holder_name"]
    assert_equal 1, missing.missing

    extra = score(expected: [ card ], actual: [ card, li ])
    assert_equal [ 1, 1 ], extra.fields["holder_name"]
    assert_equal 1, extra.extra
  end

  test "non-certificate pages found are counted" do
    score = Imports::Eval::Scorer.new(expected: { "certificates" => [ card ], "non_certificate_pages" => [ 2, 3 ] },
      actual: { "certificates" => [ card ], "non_certificate_pages" => [ 3 ] }).call

    assert_equal [ 1, 2 ], score.pages
  end

  test "an answer with no certificates scores nothing and needs nothing" do
    score = score(expected: [], actual: [])

    assert_equal [ 0, 0 ], score.fields["holder_name"]
    assert_equal 0, score.expected_count
  end

  test "verification fields are scored only for answers that have them" do
    old_answer = score(expected: [ card ], actual: [ card("certificate_issuer_code" => "REDCROSS", "verification_code" => "X") ])
    Imports::Eval::Scorer::VERIFICATION_FIELDS.each { |field| assert_equal [ 0, 0 ], old_answer.fields[field], field }
    assert_empty old_answer.mismatches

    answer = card("certificate_issuer_code" => "REDCROSS", "verification_code" => nil, "verification_url" => nil)
    new_answer = score(expected: [ answer ], actual: [ card("certificate_issuer_code" => "redcross") ])
    assert_equal [ [ 1, 1 ], [ 1, 1 ], [ 1, 1 ] ], Imports::Eval::Scorer::VERIFICATION_FIELDS.map { |field| new_answer.fields[field] }
  end

  test "verification codes ignore spaces and case; links ignore scheme, www, host case, a trailing slash and query order" do
    answer = card("verification_code" => "rc 12-34", "verification_url" => "redcross.org/take-a-class/qrcode?certnumber=1&b=2")
    got = card("verification_code" => "RC12-34", "verification_url" => "HTTPS://www.RedCross.org/take-a-class/qrcode/?b=2&certnumber=1")

    result = score(expected: [ answer ], actual: [ got ])

    assert result.correct?("verification_code")
    assert result.correct?("verification_url")
  end

  test "a different link path, code or issuer is wrong, and so is a missing certificate's" do
    answer = card("certificate_issuer_code" => "REDCROSS", "verification_code" => "RC1", "verification_url" => "redcross.org/confirm")
    got = card("certificate_issuer_code" => "AHA", "verification_code" => "RC2", "verification_url" => "redcross.org/Confirm")

    result = score(expected: [ answer ], actual: [ got ])
    assert_equal [ [ 0, 1 ] ] * 3, Imports::Eval::Scorer::VERIFICATION_FIELDS.map { |field| result.fields[field] }
    assert_includes result.mismatches, { "field" => "certificate_issuer_code", "expected" => "REDCROSS", "actual" => "AHA" }

    missing = score(expected: [ answer, card("pages" => [ 2 ]) ], actual: [])
    assert_equal [ 0, 1 ], missing.fields["verification_url"], "the older-style second answer isn't scored on it"
    assert_equal [ 0, 2 ], missing.fields["holder_name"]
  end

  private
    def score(expected:, actual:)
      Imports::Eval::Scorer.new(expected: { "certificates" => expected }, actual: { "certificates" => actual }).call
    end

    def card(overrides = {})
      { "pages" => [ 1 ], "holder_name" => "Juan A. Ortiz", "certificate_type_code" => "OSHA30",
        "certificate_name_as_printed" => "OSHA 30-Hour Construction Industry Outreach Training",
        "issuer" => "Example Safety Training LLC", "certificate_number" => "30-1234567",
        "completed_on" => "2025-03-14", "expires_on" => nil, "confidence" => 0.95, "notes" => nil }.merge(overrides)
    end
end
