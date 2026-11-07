require "test_helper"
require_relative "match_test_support"

class Imports::CreateMissingRecordsTest < ActiveSupport::TestCase
  include ImportsMatchTestSupport

  def waiting(**attrs)
    review_item(member: nil, type: nil, holder_name_raw: "ROBERT Q. EXAMPLE", certificate_name_raw: "Scaffold Safety", issuer_raw: "Summit Training", **attrs)
  end

  test "adds a crew member, type and issuer that nothing matches, and matches the item to them" do
    item = waiting

    assert_difference [ -> { CrewMember.count }, -> { CertificateType.count }, -> { CertificateIssuer.count } ], 1 do
      Imports::CreateMissingRecords.new(item).call
    end

    item.reload
    assert_equal "Robert Example", item.matched_crew_member.full_name
    assert item.person_matched?
    assert_equal Imports::CreateMissingRecords::CREATED_NOTE, item.person_suggestions.first["note"]
    assert_equal [ "Scaffold Safety", 24 ], [ item.matched_certificate_type.name, item.matched_certificate_type.validity_months ]
    assert item.type_matched?
    assert_equal "Summit Training", item.matched_certificate_issuer.name
    assert item.issuer_matched?
  end

  test "a second card for the same new person finds the first one's record" do
    Imports::CreateMissingRecords.new(waiting).call
    second = waiting(bytes: "second")

    assert_no_difference([ -> { CrewMember.count }, -> { CertificateType.count }, -> { CertificateIssuer.count } ]) do
      Imports::CreateMissingRecords.new(second).call
    end
    assert_equal "Robert Example", second.reload.matched_crew_member.full_name
  end

  test "cards with and without the middle name make one crew member, in either order" do
    [ [ "SHAMEL DESHAWN FEREBEE", "Shamel Ferebee" ], [ "Tavon Rice", "TAVON M. RICE" ], [ "Lena Ruiz", "Lena Maria Ruiz" ] ].each do |first_name, second_name|
      first = waiting(holder_name_raw: first_name, bytes: "a #{first_name}")
      second = waiting(holder_name_raw: second_name, bytes: "b #{first_name}")

      assert_difference -> { CrewMember.count }, 1, first_name do
        Imports::CreateMissingRecords.new(first).call
        Imports::CreateMissingRecords.new(second).call
      end
      assert_equal first.reload.matched_crew_member, second.reload.matched_crew_member, first_name
      assert second.person_matched?, first_name
    end
  end

  test "a fuzzy match gets its own crew member, marked a possible duplicate of the close one" do
    juan = crew_members(:juan_ortiz)
    [ "Juan Ortizes", "Jaun Ortis" ].each do |name| # a fuzzy suggestion; a low score but every word a letter off
      item = review_item(member: juan, type: certificate_types(:flagger), holder_name_raw: name, person_match: :suggested, bytes: name)

      assert_difference -> { CrewMember.count }, 1, name do
        Imports::CreateMissingRecords.new(item).call
      end

      item.reload
      assert item.person_matched?, name
      assert_equal [ name, juan ], [ item.matched_crew_member.full_name, item.matched_crew_member.possible_duplicate_of ], name
      assert_equal juan.id, item.person_suggestions.second&.dig("id"), name if name == "Juan Ortizes" # still offered
    end
  end

  test "a new person nobody is close to isn't marked a duplicate" do
    item = waiting
    Imports::CreateMissingRecords.new(item).call

    assert_nil item.reload.matched_crew_member.possible_duplicate_of
  end

  test "an ambiguous name, an inactive member's, or one a person picked still waits for a person" do
    CrewMember.create!(first_name: "Juan", last_name: "Ortiz", employer: "Skyline Tower Services")
    items = [ review_item(member: nil, holder_name_raw: "Juan Ortiz", person_match: :suggested, bytes: "twins"),
      review_item(member: nil, holder_name_raw: "Sam Price", person_match: :suggested, bytes: "inactive"),
      review_item(member: crew_members(:li_chen), holder_name_raw: "Robert Example", person_match: :picked, bytes: "picked") ]

    assert_no_difference -> { CrewMember.count } do
      items.each { Imports::CreateMissingRecords.new(it).call }
    end
    assert_equal %w[suggested suggested picked], items.map { it.reload.person_match }
  end

  test "a close spelling is matched, not added" do
    item = waiting(holder_name_raw: "JUAN ORTEZ")

    assert_no_difference -> { CrewMember.count } do
      Imports::CreateMissingRecords.new(item).call
    end
    assert_equal [ crew_members(:juan_ortiz), "matched" ], item.reload.then { [ it.matched_crew_member, it.person_match ] }
  end

  test "without a first and last name, or printed names, nothing is added" do
    item = review_item(member: nil, type: nil, holder_name_raw: "Madonna", certificate_name_raw: nil, issuer_raw: nil)

    assert_no_difference([ -> { CrewMember.count }, -> { CertificateType.count }, -> { CertificateIssuer.count } ]) do
      Imports::CreateMissingRecords.new(item).call
    end
    assert item.reload.person_unmatched?
  end
end
