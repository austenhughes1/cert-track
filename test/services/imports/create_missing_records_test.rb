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

  test "a near match stays a suggestion for a person to confirm" do
    item = review_item(member: crew_members(:juan_ortiz), type: certificate_types(:flagger), holder_name_raw: "Jaun Ortis", person_match: :suggested,
      type_match: :suggested, issuer_match: :suggested, certificate_name_raw: "Flagger", issuer_raw: "Summit")

    assert_no_difference([ -> { CrewMember.count }, -> { CertificateType.count }, -> { CertificateIssuer.count } ]) do
      Imports::CreateMissingRecords.new(item).call
    end
    assert item.reload.person_suggested?
  end

  test "without a first and last name, or printed names, nothing is added" do
    item = review_item(member: nil, type: nil, holder_name_raw: "Madonna", certificate_name_raw: nil, issuer_raw: nil)

    assert_no_difference([ -> { CrewMember.count }, -> { CertificateType.count }, -> { CertificateIssuer.count } ]) do
      Imports::CreateMissingRecords.new(item).call
    end
    assert item.reload.person_unmatched?
  end
end
