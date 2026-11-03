require "test_helper"

class CrewMemberTest < ActiveSupport::TestCase
  test "requires first and last name" do
    member = CrewMember.new(first_name: " ", last_name: "")
    assert_not member.valid?
    assert_includes member.errors[:first_name], "can't be blank"
    assert_includes member.errors[:last_name], "can't be blank"
  end

  test "normalizes names, email and aliases" do
    member = CrewMember.create!(first_name: "  Ana ", last_name: " Ruiz  ", preferred_name: " ", email: " Ana@Example.COM ",
      name_aliases: [ " Ana  Ruiz ", "", "ana ruiz", "A. Ruiz", nil ])
    assert_equal "Ana", member.first_name
    assert_equal "Ruiz", member.last_name
    assert_nil member.preferred_name
    assert_equal "ana@example.com", member.email
    assert_equal [ "Ana Ruiz", "A. Ruiz" ], member.name_aliases
  end

  test "blank email is nil and bad email is invalid" do
    assert_nil CrewMember.new(first_name: "A", last_name: "B", email: "  ").email
    assert_not CrewMember.new(first_name: "Al", last_name: "B", email: "not-an-email").valid?
  end

  test "defaults" do
    member = CrewMember.new
    assert member.active
    assert_not member.expiry_emails_opt_in
    assert_equal [], member.name_aliases
  end

  test "full_name, display_name and sort_name" do
    maria = crew_members(:maria_garcia)
    assert_equal "Maria Garcia", maria.full_name
    assert_equal "Mari Garcia", maria.display_name
    assert_equal "Garcia, Maria", maria.sort_name
    assert_equal "Juan Ortiz", crew_members(:juan_ortiz).display_name
  end

  test "active and inactive scopes" do
    assert_includes CrewMember.active, crew_members(:juan_ortiz)
    assert_not_includes CrewMember.active, crew_members(:sam_inactive)
    assert_equal [ crew_members(:sam_inactive) ], CrewMember.inactive.to_a
  end

  test "search tolerates typos" do
    assert_equal crew_members(:juan_ortiz), CrewMember.search("Jaun Ortis").first
  end

  test "search matches substrings, preferred names and aliases" do
    assert_includes CrewMember.search("ort"), crew_members(:juan_ortiz)
    assert_includes CrewMember.search("Mari"), crew_members(:maria_garcia)
    assert_includes CrewMember.search("Dave Miller"), crew_members(:dave_miller)
    assert_equal crew_members(:juan_ortiz), CrewMember.search("Jon Ortiz").first
    assert_equal crew_members(:maria_garcia), CrewMember.search("garcia-lopez").first
  end

  test "search excludes unrelated names and ranks the best match first" do
    results = CrewMember.search("Li Chen")
    assert_equal crew_members(:li_chen), results.first
    assert_not_includes results, crew_members(:juan_ortiz)
  end

  test "search sanitizes input and stays chainable" do
    assert_empty CrewMember.search("%' OR 1=1 --")
    assert_equal CrewMember.count, CrewMember.search("  ").count
    assert_equal [ crew_members(:sam_inactive) ], CrewMember.inactive.search("Sam Price").to_a
    assert_equal 0, CrewMember.active.search("Sam Price").count
  end

  test "normalized_names covers full, preferred + last and aliases" do
    assert_equal [ "juan ortiz", "jon ortiz", "juan ortiz ruiz" ], crew_members(:juan_ortiz).normalized_names
    assert_equal [ "maria garcia", "mari garcia", "maria garcia lopez" ], crew_members(:maria_garcia).normalized_names
  end

  test "find_by_normalized_name matches exact normalized names only" do
    assert_equal crew_members(:juan_ortiz), CrewMember.find_by_normalized_name("JUAN A. ORTIZ")
    assert_equal crew_members(:juan_ortiz), CrewMember.find_by_normalized_name("Jon  Ortiz")
    assert_equal crew_members(:maria_garcia), CrewMember.find_by_normalized_name("Mari Garcia")
    assert_equal crew_members(:maria_garcia), CrewMember.find_by_normalized_name("Maria Garcia Lopez")
    assert_nil CrewMember.find_by_normalized_name("Jaun Ortis")
    assert_nil CrewMember.find_by_normalized_name("")
  end

  test "an initial alias does not match other people with the same surname" do
    john = CrewMember.create!(first_name: "John", last_name: "Smith")
    karen = CrewMember.create!(first_name: "Karen", last_name: "Smith", name_aliases: [ "K. Smith" ])
    assert john.add_alias!("J. Smith")

    assert_equal john, CrewMember.find_by_normalized_name("J. Smith")
    assert_equal karen, CrewMember.find_by_normalized_name("K. Smith")
    assert_equal karen, CrewMember.find_by_normalized_name("SMITH, KAREN")
    assert_nil CrewMember.find_by_normalized_name("L. Smith")
  end

  test "a bare surname is never an exact match" do
    CrewMember.create!(first_name: "John", last_name: "Smith", name_aliases: [ "Smith" ])

    assert_nil CrewMember.find_by_normalized_name("SMITH")
    assert_empty CrewMember.matching_normalized_name("Smith.")
  end

  test "find_by_normalized_name prefers active members and matching_normalized_name returns all" do
    twin = CrewMember.create!(first_name: "Sam", last_name: "Price")
    assert_equal twin, CrewMember.find_by_normalized_name("sam price")
    assert_equal [ twin, crew_members(:sam_inactive) ], CrewMember.matching_normalized_name("Sam Price")
  end

  test "add_alias! stores new spellings once" do
    juan = crew_members(:juan_ortiz)
    assert juan.add_alias!(" Jaun  Ortis ")
    assert_equal "Jaun Ortis", juan.reload.name_aliases.last
    assert_not juan.add_alias!("jaun ortis")
    assert_not juan.add_alias!("Juan A. Ortiz") # normalizes to the full name
    assert_not juan.add_alias!("  ")
    assert_not juan.add_alias!("Ortiz") # a bare surname could be anyone
    assert_not juan.add_alias!("J.")
    assert_equal 1, juan.reload.name_aliases.count("Jaun Ortis")
  end

  test "current_certificate_for uses preloaded certificates" do
    juan = CrewMember.includes(:current_certificates).find(crew_members(:juan_ortiz).id)
    expected, flagger, cdl_id = certificates(:juan_flagger), certificate_types(:flagger), certificate_types(:cdl_a).id
    assert_queries_count(0) do
      assert_equal expected, juan.current_certificate_for(flagger)
      assert_nil juan.current_certificate_for(cdl_id)
    end
    assert_equal certificates(:juan_flagger), crew_members(:juan_ortiz).current_certificate_for(certificate_types(:flagger))
  end

  test "employer_names" do
    assert_equal [ "ABA Ventures", "Skyline Tower Services" ], CrewMember.employer_names
  end

  test "cannot be destroyed while certificates exist" do
    member = crew_members(:juan_ortiz)
    assert_not member.destroy
    assert CrewMember.exists?(member.id)
  end

  test "members without history can be destroyed" do
    assert CrewMember.create!(first_name: "Temp", last_name: "Worker").destroy
  end
end
