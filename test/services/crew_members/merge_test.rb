require "test_helper"
require_relative "../imports/match_test_support"

class CrewMembers::MergeTest < ActiveSupport::TestCase
  include ImportsMatchTestSupport

  setup do
    @juan = crew_members(:juan_ortiz) # kept
    @li = crew_members(:li_chen)      # merged in: osha30, flagger, first_aid; also on tower_2417
  end

  def merge
    CrewMembers::Merge.new(from: @li, into: @juan).call
  end

  test "moves every certificate; for a type both have, the latest stays current" do
    result = merge

    assert_equal 3, result.certificates
    assert_equal 9, @juan.certificates.count
    current = @juan.certificates.current.includes(:certificate_type).group_by(&:certificate_type)
    assert current.values.all?(&:one?), "one current certificate per type"
    assert_equal certificates(:li_osha30), current[certificate_types(:osha30)].sole # completed later
    assert_equal certificates(:li_flagger), current[certificate_types(:flagger)].sole
    assert_equal certificates(:juan_first_aid), current[certificate_types(:first_aid)].sole
    assert certificates(:li_first_aid).reload.superseded?
    assert_not CrewMember.exists?(@li.id)
  end

  test "keeps expiry alerts already sent and a check's record of the person" do
    flagger = certificates(:li_flagger)
    sent = ExpiryNotification.create!(certificate: flagger, threshold: :d90, recipient_email: "li.chen@skyline.example.com", sent_at: 1.day.ago)
    details = { Authenticity::CHECKED_INPUTS_KEY => { "person" => Authenticity.input_digest(@li.id), "verification code" => "x" } }
    flagger.update_columns(authenticity_details: details)

    merge

    assert ExpiryNotification.exists?(sent.id)
    assert_equal Authenticity.input_digest(@juan.id), flagger.reload.authenticity_details.dig(Authenticity::CHECKED_INPUTS_KEY, "person")
    assert_equal "x", flagger.authenticity_details.dig(Authenticity::CHECKED_INPUTS_KEY, "verification code")
  end

  test "a project both are on keeps one assignment, with the role override; others move" do
    other = Project.where.not(id: projects(:tower_2417).id).first
    ProjectAssignment.create!(project: other, crew_member: @li)

    assert_equal 2, merge.projects

    tower = @juan.project_assignments.where(project: projects(:tower_2417)).sole
    assert_equal [ crew_roles(:climber), project_assignments(:tower_juan).starts_on ], [ tower.crew_role, tower.starts_on ]
    assert @juan.project_assignments.exists?(project: other)
  end

  test "import items and waiting cards' suggestions move to the kept record" do
    waiting = review_item(member: @li, holder_name_raw: "Li Chen", person_match: :suggested,
      person_suggestions: [ { "id" => @li.id, "name" => "Li Chen", "similarity" => 1.0 }, { "id" => @juan.id, "name" => "Juan Ortiz", "similarity" => 0.2 } ])
    other = review_item(member: nil, holder_name_raw: "Lee Chen", person_match: :unmatched, bytes: "other",
      person_suggestions: [ { "id" => @li.id, "name" => "Li Chen", "similarity" => 0.5 } ])

    merge

    assert_equal @juan, waiting.reload.matched_crew_member
    assert_equal [ @juan.id ], waiting.person_suggestions.map { it["id"] } # not listed twice
    assert_equal [ [ @juan.id, "Juan Ortiz", 0.5 ] ], other.reload.person_suggestions.map { it.values_at("id", "name", "similarity") }
  end

  test "names become other spellings and blank details are filled in, never overwritten" do
    @li.update!(preferred_name: "Lee", name_aliases: [ "Chen Li" ], notes: "Climbs well.", expiry_emails_opt_in: true)
    @juan.update!(employer: nil, notes: "Foreman's pick.")

    merge
    @juan.reload

    assert_includes @juan.name_aliases, "Li Chen"
    assert_includes @juan.name_aliases, "Lee Chen"
    assert_includes @juan.name_aliases, "Chen Li"
    assert_equal crew_members(:juan_ortiz).reload, Imports::PersonMatcher.new("Li Chen").call.crew_member
    assert_equal "Skyline Tower Services", @juan.employer
    assert_equal "Lee", @juan.preferred_name
    assert_equal crew_members(:juan_ortiz).email, @juan.email # had one
    assert_equal "Foreman's pick.\n\nClimbs well.", @juan.notes
    assert @juan.expiry_emails_opt_in?
  end

  test "possible duplicate marks follow the kept record" do
    marked = CrewMember.create!(first_name: "Li", last_name: "Chan", possible_duplicate_of: @li)
    @juan.update!(possible_duplicate_of: @li)

    merge

    assert_equal @juan, marked.reload.possible_duplicate_of
    assert_nil @juan.reload.possible_duplicate_of
  end

  test "preview counts what would move and changes nothing" do
    preview = CrewMembers::Merge.new(from: @li, into: @juan).preview

    assert_equal 3, preview.certificates
    assert_equal [ certificate_types(:first_aid), certificate_types(:flagger), certificate_types(:osha30) ].sort_by(&:name), preview.shared_types
    assert_equal [ projects(:tower_2417) ], preview.shared_projects
    assert_equal 1, preview.projects
    assert CrewMember.exists?(@li.id)
  end

  test "a record can't be merged into itself or nobody" do
    assert_raises(CrewMembers::Merge::Invalid) { CrewMembers::Merge.new(from: @li, into: @li) }
    assert_raises(CrewMembers::Merge::Invalid) { CrewMembers::Merge.new(from: @li, into: nil) }
  end
end
