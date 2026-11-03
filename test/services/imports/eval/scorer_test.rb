require "test_helper"

class Imports::Eval::ScorerTest < ActiveSupport::TestCase
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
