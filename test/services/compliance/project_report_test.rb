require "test_helper"

class Compliance::ProjectReportTest < ActiveSupport::TestCase
  setup do
    @today = Date.current
    @tower = projects(:tower_2417)
  end

  # code => status for every cell of every row, keyed by last name.
  def matrix(report)
    report.rows.to_h do |row|
      [ row.crew_member.last_name, row.cells.to_h { |cell| [ cell.certificate_type.code, cell.status ] } ]
    end
  end

  # Counts the SQL statements a block runs, ignoring schema and transaction ones. The query cache
  # is off inside the block so the count is deterministic.
  def count_queries(&block)
    queries = []
    counter = lambda do |*, payload|
      queries << payload[:sql] unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { ActiveRecord::Base.uncached(&block) }
    queries
  end

  def create_member(first, last, role, **attributes)
    CrewMember.create!(first_name: first, last_name: last, crew_role: role && crew_roles(role), **attributes)
  end

  def certify(member, type, expires_on: :never, completed_on: @today - 100)
    attributes = { crew_member: member, certificate_type: certificate_types(type), completed_on: completed_on }
    attributes[:expires_on] = expires_on unless expires_on == :never
    Certificate.create!(attributes)
  end

  test "Phase 1 acceptance: 5 required types, one role-specific, 3 people" do
    project = Project.create!(name: "Acceptance", code: "ACC1", starts_on: @today - 10, ends_on: @today + 120)
    %i[osha30 flagger first_aid cdl_a].each { |type| project.project_requirements.create!(certificate_type: certificate_types(type)) }
    project.project_requirements.create!(certificate_type: certificate_types(:climber), crew_role: crew_roles(:climber))

    ana = create_member("Ana", "Alvarez", :climber)
    ben = create_member("Ben", "Brooks", :laborer)
    cy = create_member("Cy", "Cole", :operator)
    [ ana, ben, cy ].each { |member| project.project_assignments.create!(crew_member: member) }

    certify(ana, :osha30)                                 # never expires
    certify(ana, :flagger, expires_on: @today + 10)
    certify(ana, :first_aid, expires_on: @today + 60)
    certify(ana, :cdl_a, expires_on: @today - 1)
    certify(ben, :osha30)
    certify(ben, :flagger, expires_on: @today + 400)
    certify(ben, :cdl_a, expires_on: @today + 200)
    certify(ben, :climber, expires_on: @today + 400)      # held, but not required of a laborer
    certify(cy, :flagger, expires_on: @today - 30)
    certify(cy, :first_aid, expires_on: @today + 30)
    certify(cy, :cdl_a, expires_on: @today + 500)

    report = Compliance::ProjectReport.new(project, today: @today)

    assert_equal %w[OSHA30 FLAGGER FIRSTAID CLIMBER CDLA], report.columns.map(&:code)
    assert_equal({
      "Alvarez" => { "OSHA30" => "valid", "FLAGGER" => "expiring", "FIRSTAID" => "lapses_on_project", "CLIMBER" => "missing", "CDLA" => "expired" },
      "Brooks" => { "OSHA30" => "valid", "FLAGGER" => "valid", "FIRSTAID" => "missing", "CLIMBER" => "not_required", "CDLA" => "valid" },
      "Cole" => { "OSHA30" => "missing", "FLAGGER" => "expired", "FIRSTAID" => "expiring", "CLIMBER" => "not_required", "CDLA" => "valid" }
    }, matrix(report))

    not_required = report.row_for(ben).cell_for(certificate_types(:climber))
    assert_not not_required.required?
    assert_nil not_required.certificate, "not_required cells carry no certificate"
    assert_nil not_required.expires_on

    assert_equal({ "missing" => 3, "expired" => 2, "expiring" => 2, "lapses_on_project" => 1, "valid" => 5 }, report.summary)
    assert_equal %w[expired missing expired], [ ana, ben, cy ].map { |member| report.row_for(member).worst_status }
  end

  test "rows are active assignments ordered by last then first name" do
    report = Compliance::ProjectReport.new(@tower, today: @today)

    assert_equal %w[Chen Garcia Miller Ortiz], report.rows.map { |row| row.crew_member.last_name }
    assert_equal project_assignments(:tower_li_chen), report.rows.first.assignment
    assert_equal crew_members(:li_chen), report.rows.first.crew_member
  end

  test "columns are every required type, by position then name" do
    project = Project.create!(name: "Ordering")
    no_position = CertificateType.create!(name: "Aaa Unpositioned", code: "AAA")
    late = CertificateType.create!(name: "Zzz Late", code: "ZZZ", position: 50)
    [ no_position, late, certificate_types(:first_aid), certificate_types(:osha30) ].each do |type|
      project.project_requirements.create!(certificate_type: type)
    end
    project.project_requirements.create!(certificate_type: certificate_types(:first_aid), crew_role: crew_roles(:climber))

    report = Compliance::ProjectReport.new(project, today: @today)

    assert_equal %w[OSHA30 FIRSTAID ZZZ AAA], report.columns.map(&:code)
    assert_equal %w[OSHA30 FLAGGER FIRSTAID CLIMBER CDLA], Compliance::ProjectReport.new(@tower).columns.map(&:code)
  end

  test "fixture statuses on tower_2417" do
    report = Compliance::ProjectReport.new(@tower, today: @today)

    assert_equal({
      "Chen" => { "OSHA30" => "valid", "FLAGGER" => "valid", "FIRSTAID" => "expired", "CLIMBER" => "missing", "CDLA" => "not_required" },
      "Garcia" => { "OSHA30" => "valid", "FLAGGER" => "missing", "FIRSTAID" => "expired", "CLIMBER" => "not_required", "CDLA" => "not_required" },
      "Miller" => { "OSHA30" => "valid", "FLAGGER" => "valid", "FIRSTAID" => "missing", "CLIMBER" => "not_required", "CDLA" => "expiring" },
      "Ortiz" => { "OSHA30" => "valid", "FLAGGER" => "expiring", "FIRSTAID" => "lapses_on_project", "CLIMBER" => "valid", "CDLA" => "not_required" }
    }, matrix(report))
  end

  test "the assignment role overrides the member role; a blank one falls back to it" do
    report = Compliance::ProjectReport.new(@tower, today: @today)

    li = report.row_for(crew_members(:li_chen)) # operator by default, climber on this project
    assert_equal crew_roles(:climber), li.role
    assert li.cell_for(certificate_types(:climber)).required?
    assert_not li.cell_for(certificate_types(:cdl_a)).required?

    juan = report.row_for(crew_members(:juan_ortiz)) # no assignment role
    assert_equal crew_roles(:climber), juan.role
    assert juan.cell_for(certificate_types(:climber)).required?

    dave = report.row_for(crew_members(:dave_miller))
    assert_equal crew_roles(:operator), dave.role
    assert dave.cell_for(certificate_types(:cdl_a)).required?
  end

  test "a person with no role gets only the everyone requirements" do
    member = create_member("Nora", "Norole", nil)
    @tower.project_assignments.create!(crew_member: member)

    row = Compliance::ProjectReport.new(@tower, today: @today).row_for(member)

    assert_nil row.role
    assert_equal %w[OSHA30 FLAGGER FIRSTAID], row.required_cells.map { |cell| cell.certificate_type.code }
    assert_equal "missing", row.worst_status
  end

  test "expiry boundaries" do
    expires_on = certificates(:juan_first_aid).expires_on
    status = ->(today, project = @tower) do
      Compliance::ProjectReport.new(project, today: today).row_for(crew_members(:juan_ortiz)).cell_for(certificate_types(:first_aid)).status
    end

    assert_equal "expired", status.(expires_on + 1)
    assert_equal "expiring", status.(expires_on)
    assert_equal "expiring", status.(expires_on - 30)
    assert_equal "lapses_on_project", status.(expires_on - 31)
    assert_operator @tower.ends_on, :>, expires_on

    @tower.update!(ends_on: nil)
    assert_equal "valid", status.(expires_on - 31)
    @tower.update!(ends_on: expires_on)
    assert_equal "valid", status.(expires_on - 31), "expiring on the last day is not a lapse"
  end

  test "a never-expiring certificate is valid" do
    cell = Compliance::ProjectReport.new(@tower, today: @today).row_for(crew_members(:juan_ortiz)).cell_for(certificate_types(:osha30))

    assert_equal "valid", cell.status
    assert_nil cell.expires_on
    assert_equal certificates(:juan_osha30), cell.certificate
  end

  test "only the current certificate counts" do
    report = Compliance::ProjectReport.new(@tower, today: @today)
    assert_equal certificates(:juan_flagger), report.row_for(crew_members(:juan_ortiz)).cell_for(certificate_types(:flagger)).certificate

    renewed = certify(crew_members(:maria_garcia), :first_aid, completed_on: @today - 1, expires_on: @today + 700)
    cell = Compliance::ProjectReport.new(@tower, today: @today).row_for(crew_members(:maria_garcia)).cell_for(certificate_types(:first_aid))

    assert_equal renewed, cell.certificate
    assert_equal "valid", cell.status
  end

  test "inactive crew members are left out" do
    @tower.project_assignments.create!(crew_member: crew_members(:sam_inactive))
    report = Compliance::ProjectReport.new(@tower, today: @today)

    assert_nil report.row_for(crew_members(:sam_inactive))
    assert_equal 4, report.rows.size

    closed = Compliance::ProjectReport.new(projects(:closed_2390), today: @today)
    assert_equal [ crew_members(:juan_ortiz) ], closed.rows.map(&:crew_member)
  end

  test "assignments that ended are neither rows nor gaps; upcoming ones are" do
    left = create_member("Rux", "Leaver", nil)
    joining = create_member("Nia", "Joiner", nil)
    @tower.project_assignments.create!(crew_member: left, starts_on: @today - 30, ends_on: @today - 3)
    @tower.project_assignments.create!(crew_member: joining, starts_on: @today + 14)
    report = Compliance::ProjectReport.new(@tower, today: @today)

    assert_nil report.row_for(left)
    assert_not_includes report.gaps.map(&:crew_member), left
    assert_equal %w[missing missing missing], report.row_for(joining).gaps.map(&:status)
    assert_includes report.to_csv, "Joiner"
    assert_not_includes report.to_csv, "Leaver"

    on_last_day = Compliance::ProjectReport.new(@tower, today: @today - 3)
    assert on_last_day.row_for(left)
  end

  test "row_for and cell_for accept records or ids" do
    report = Compliance::ProjectReport.new(@tower, today: @today)
    row = report.row_for(crew_members(:dave_miller).id)

    assert_equal crew_members(:dave_miller), row.crew_member
    assert_equal row.cell_for(certificate_types(:cdl_a)), row.cell_for(certificate_types(:cdl_a).id)
    assert_nil row.cell_for(certificate_types(:retired_hazwoper)), "not a column"
    assert_nil report.row_for(crew_members(:sam_inactive))
    assert report.rows.all? { |each_row| report.columns.all? { |type| each_row.cell_for(type) } }
  end

  test "cells" do
    row = Compliance::ProjectReport.new(@tower, today: @today).row_for(crew_members(:dave_miller))
    cdl = row.cell_for(certificate_types(:cdl_a))
    first_aid = row.cell_for(certificate_types(:first_aid))

    assert cdl.required?
    assert_not cdl.gap?
    assert_equal certificates(:dave_cdl_a).expires_on, cdl.expires_on
    assert_equal 25, cdl.days_until_expiry(today: @today)
    assert first_aid.gap?
    assert_nil first_aid.certificate
    assert_nil first_aid.days_until_expiry
    assert_equal "missing", row.worst_status
    assert_equal [ first_aid ], row.gaps
  end

  test "summary counts required cells by status" do
    report = Compliance::ProjectReport.new(@tower, today: @today)

    assert_equal({ "missing" => 3, "expired" => 2, "expiring" => 2, "lapses_on_project" => 1, "valid" => 7 }, report.summary)
    assert_equal Compliance::STATUSES, report.summary.keys
    assert_not report.compliant?
  end

  test "gaps are the missing and expired cells in row then column order" do
    gaps = Compliance::ProjectReport.new(@tower, today: @today).gaps

    assert_equal [
      [ "Chen", "FIRSTAID", "expired" ], [ "Chen", "CLIMBER", "missing" ],
      [ "Garcia", "FLAGGER", "missing" ], [ "Garcia", "FIRSTAID", "expired" ],
      [ "Miller", "FIRSTAID", "missing" ]
    ], gaps.map { |gap| [ gap.crew_member.last_name, gap.certificate_type.code, gap.status ] }
    assert gaps.all? { |gap| gap.project == @tower }
    assert_equal certificates(:li_first_aid), gaps.first.certificate
    assert_nil gaps.second.certificate
  end

  test "an empty project" do
    project = Project.create!(name: "Empty")
    report = Compliance::ProjectReport.new(project, today: @today)

    assert_equal [], report.columns
    assert_equal [], report.rows
    assert_equal Compliance::STATUSES.index_with(0), report.summary
    assert report.compliant?
    assert_equal "Last name,First name,Role,Employer\n", report.to_csv
  end

  test "people on a project without requirements still get rows" do
    project = Project.create!(name: "No requirements")
    project.project_assignments.create!(crew_member: crew_members(:juan_ortiz))
    row = Compliance::ProjectReport.new(project, today: @today).rows.sole

    assert_equal [], row.cells
    assert_nil row.worst_status
  end

  test "to_csv" do
    expiry = ->(fixture) { certificates(fixture).expires_on.iso8601 }
    csv = Compliance::ProjectReport.new(@tower, today: @today).to_csv

    assert_equal <<~CSV, csv
      Last name,First name,Role,Employer,OSHA30,FLAGGER,FIRSTAID,CLIMBER,CDLA
      Chen,Li,Climber,Skyline Tower Services,valid,valid (#{expiry.(:li_flagger)}),expired (#{expiry.(:li_first_aid)}),missing,not required
      Garcia,Maria,Foreman,ABA Ventures,valid,missing,expired (#{expiry.(:maria_first_aid)}),not required,not required
      Miller,David,Operator,ABA Ventures,valid,valid (#{expiry.(:dave_flagger)}),missing,not required,expiring (#{expiry.(:dave_cdl_a)})
      Ortiz,Juan,Climber,ABA Ventures,valid,expiring (#{expiry.(:juan_flagger)}),lapses on project (#{expiry.(:juan_first_aid)}),valid (#{expiry.(:juan_climber)}),not required
    CSV
  end

  test "to_csv quotes and defuses spreadsheet formulas" do
    project = Project.create!(name: "Quoting")
    project.project_requirements.create!(certificate_type: certificate_types(:osha30))
    member = CrewMember.create!(first_name: %(Robert "Bob"), last_name: "=HYPERLINK(1)", employer: "Acme, Inc.")
    project.project_assignments.create!(crew_member: member)

    assert_equal <<~CSV, Compliance::ProjectReport.new(project, today: @today).to_csv
      Last name,First name,Role,Employer,OSHA30
      '=HYPERLINK(1),"Robert ""Bob""",,"Acme, Inc.",missing
    CSV
  end

  test "csv_filename" do
    assert_equal "2417-compliance-#{@today.iso8601}.csv", Compliance::ProjectReport.new(@tower, today: @today).csv_filename
  end

  test "is lazy and runs a fixed handful of queries" do
    report = nil
    assert_empty count_queries { report = Compliance::ProjectReport.new(@tower, today: @today) }

    queries = count_queries { report.rows; report.summary; report.gaps; report.to_csv }
    assert_operator queries.size, :<=, 4, queries.join("\n")

    assert_empty count_queries {
      report.rows.each do |row|
        row.assignment.project
        row.role
        row.cells.each { |cell| cell.certificate&.crew_member && cell.certificate&.certificate_type }
      end
    }
  end

  test "certificates lists the current certificates in required cells" do
    report = Compliance::ProjectReport.new(@tower, today: @today)

    assert_includes report.certificates, certificates(:li_flagger)
    assert_not_includes report.certificates, certificates(:juan_flagger_old)
    assert_equal 12, report.certificates.size
  end

  test "for_projects shares one dataset across projects" do
    closed = projects(:closed_2390)
    reports = nil
    queries = count_queries do
      reports = Compliance::ProjectReport.for_projects([ @tower, closed ], today: @today)
      reports.each(&:to_csv)
    end

    assert_operator queries.size, :<=, 4, queries.join("\n")
    assert_equal [ @tower, closed ], reports.map(&:project)
    assert_equal matrix(Compliance::ProjectReport.new(@tower, today: @today)), matrix(reports.first)
    assert_equal({ "Ortiz" => { "OSHA30" => "valid", "FIRSTAID" => "valid" } }, matrix(reports.second)) # ended before it lapses
  end

  test "50 crew by 15 types stays bounded and fast" do
    type_ids = CertificateType.insert_all!(
      15.times.map { |i| { name: "Perf type #{i}", code: "PERF#{i}", position: 100 + i, validity_months: 24 } }, returning: :id
    ).rows.flatten
    project = Project.create!(name: "Performance", ends_on: @today + 90)
    ProjectRequirement.insert_all!(type_ids.map { |id| { project_id: project.id, certificate_type_id: id } })
    ProjectRequirement.insert_all!(type_ids.first(3).map { |id| { project_id: project.id, certificate_type_id: id, crew_role_id: crew_roles(:operator).id } })
    member_ids = CrewMember.insert_all!(
      50.times.map { |i| { first_name: "Worker", last_name: "Perf#{i.to_s.rjust(2, "0")}", crew_role_id: crew_roles(:operator).id } }, returning: :id
    ).rows.flatten
    ProjectAssignment.insert_all!(member_ids.map { |id| { project_id: project.id, crew_member_id: id } })
    certificates = member_ids.each_with_index.flat_map do |member_id, i|
      type_ids.each_with_index.filter_map do |type_id, j|
        next if (i + j) % 7 == 0 # some missing
        { crew_member_id: member_id, certificate_type_id: type_id, completed_on: @today - 400,
          expires_on: @today + ((i * 15 + j) % 120) - 20, expires_on_source: 2 }
      end
    end
    Certificate.insert_all!(certificates)

    report = Compliance::ProjectReport.new(project, today: @today)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    queries = count_queries { report.rows; report.summary; report.gaps; report.to_csv }
    elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000

    assert_operator queries.size, :<=, 4, queries.join("\n")
    assert_operator elapsed_ms, :<, 500, "report took #{elapsed_ms.round} ms"
    assert_equal 50, report.rows.size
    assert_equal 15, report.columns.size
    assert_equal 750, report.summary.values.sum
    assert_equal certificates.size, report.certificates.size
  end
end
