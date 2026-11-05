# Idempotent: safe to run repeatedly (bin/rails db:seed). Existing rows are left as the
# owner edited them; only missing ones are created.

# Example master list (docs/PLAN.md). The owner edits the real list. Every type lasts 2 years
# until the owner changes it, except OSHA 10 and 30, which never expire (owner's rule, Nov 5, 2026).
MASTER_LIST = [
  [ "OSHA10", "OSHA 10 Construction", "OSHA Outreach Training Program", [ "OSHA 10-Hour Construction Industry Outreach Training", "OSHA 10 Hour" ] ],
  [ "OSHA30", "OSHA 30 Construction", "OSHA Outreach Training Program", [ "OSHA 30-Hour Construction Industry Outreach Training", "OSHA 30 Hour" ] ],
  [ "FIRSTAID", "First Aid/CPR/AED", nil, [ "Adult First Aid/CPR/AED", "First Aid CPR AED", "CPR/AED" ] ],
  [ "FLAGGER", "Flagger", nil, [ "Flagger Certification", "Traffic Control Flagger", "Certified Flagger" ] ],
  [ "COMPPERSON", "Competent Person (Excavation and Trenching)", nil, [ "Excavation Competent Person", "Trenching and Excavation Competent Person" ] ],
  [ "CONFSPACE", "Confined Space Entry", nil, [ "Confined Space Entrant", "Permit-Required Confined Space" ] ],
  [ "FALLPROT", "Fall Protection", nil, [ "Fall Protection Training", "Fall Protection Awareness" ] ],
  [ "CLIMBER", "Authorized Climber", nil, [ "Authorized Climber/Rescuer", "Tower Climber" ] ],
  [ "CLIMBRESCUE", "Climber Rescue", nil, [ "Tower Rescue", "Climber Rescue Training" ] ],
  [ "RFSAFETY", "RF Safety Awareness", nil, [ "RF Awareness", "Radio Frequency Safety" ] ],
  [ "FIBERTECH", "Fiber Optic Technician", nil, [ "Certified Fiber Optic Technician", "CFOT" ] ],
  [ "CDLA", "CDL Class A", nil, [ "Commercial Driver License Class A", "Class A CDL" ] ],
  [ "AERIAL", "Aerial Lift Operator", nil, [ "Aerial Work Platform Operator", "MEWP Operator", "Boom Lift Operator" ] ],
  [ "FORKLIFT", "Forklift or Telehandler Operator", nil, [ "Powered Industrial Truck Operator", "Forklift Operator", "Telehandler Operator" ] ],
  [ "RIGGER", "Rigger and Signal Person", nil, [ "Qualified Rigger", "Signal Person", "Rigging and Signaling" ] ]
].freeze

MASTER_LIST.each.with_index(1) do |(code, name, issuing_body, aliases), position|
  CertificateType.find_or_create_by!(code: code) do |type|
    type.name = name
    type.issuing_body = issuing_body
    type.aliases = aliases
    type.position = position
    type.validity_months = CertificateType::DEFAULT_VALIDITY_MONTHS unless %w[OSHA10 OSHA30].include?(code)
  end
end

%w[Foreman Operator Laborer Climber Driver].each { |name| CrewRole.find_or_create_by!(name: name) }

# Certificate issuers and how each is verified (config/certificate_issuers.yml, Phase 3b).
CertificateIssuer.seed_defaults!

return unless Rails.env.development?

# --- Development only: sign-in accounts and a small demo dataset ---

[
  [ "admin@example.com", "Ada Admin", :admin ],
  [ "manager@example.com", "Manny Manager", :manager ],
  [ "viewer@example.com", "Vera Viewer", :viewer ]
].each do |email, name, role|
  User.find_or_create_by!(email_address: email) do |user|
    user.name = name
    user.role = role
    user.password = "password"
    user.receives_digest = role != :viewer
  end
end

today = Date.current
roles = CrewRole.all.index_by(&:name)
types = CertificateType.all.index_by(&:code)
manager = User.find_by!(email_address: "manager@example.com")

crew = [
  { first_name: "Juan", last_name: "Ortiz", name_aliases: [ "Jon Ortiz" ], email: "juan.ortiz@example.com", crew_role: roles["Climber"], expiry_emails_opt_in: true },
  { first_name: "Maria", last_name: "Garcia", preferred_name: "Mari", email: "maria.garcia@example.com", crew_role: roles["Foreman"] },
  { first_name: "Li", last_name: "Chen", employer: "Skyline Tower Services", email: "li.chen@skyline.example.com", crew_role: roles["Climber"] },
  { first_name: "David", last_name: "Miller", preferred_name: "Dave", crew_role: roles["Driver"] },
  { first_name: "Ana", last_name: "Ruiz", email: "ana.ruiz@example.com", crew_role: roles["Operator"] },
  { first_name: "Tom", last_name: "Becker", crew_role: roles["Laborer"] },
  { first_name: "Sam", last_name: "Price", crew_role: roles["Laborer"], active: false, notes: "Left the company." }
].to_h do |attrs|
  member = CrewMember.find_or_create_by!(first_name: attrs[:first_name], last_name: attrs[:last_name]) do |m|
    m.assign_attributes({ employer: "ABA Ventures" }.merge(attrs))
  end
  [ attrs[:first_name], member ]
end

projects = {
  tower: Project.find_or_create_by!(code: "2417") do |p|
    p.assign_attributes(name: "Tower 2417 Upgrade", client: "Prime Wireless", location: "Golden, CO",
      starts_on: today - 30, ends_on: today + 120, status: :active)
  end,
  rooftop: Project.find_or_create_by!(code: "2420") do |p|
    p.assign_attributes(name: "Rooftop 2420 Small Cell", client: "Metro Towers", location: "Denver, CO",
      starts_on: today + 14, ends_on: today + 200, status: :planned)
  end
}

[
  [ :tower, "OSHA30", nil ], [ :tower, "FIRSTAID", nil ], [ :tower, "FLAGGER", nil ],
  [ :tower, "CLIMBER", "Climber" ], [ :tower, "CDLA", "Driver" ],
  [ :rooftop, "OSHA10", nil ], [ :rooftop, "FIRSTAID", nil ], [ :rooftop, "RFSAFETY", nil ],
  [ :rooftop, "AERIAL", "Operator" ]
].each do |project, code, role|
  ProjectRequirement.find_or_create_by!(project: projects[project], certificate_type: types.fetch(code), crew_role: roles[role])
end

[
  [ :tower, "Juan" ], [ :tower, "Maria" ], [ :tower, "Li" ], [ :tower, "David" ], [ :tower, "Tom", "Climber" ],
  [ :rooftop, "Juan" ], [ :rooftop, "Ana" ], [ :rooftop, "Maria" ]
].each do |project, first_name, role|
  ProjectAssignment.find_or_create_by!(project: projects[project], crew_member: crew.fetch(first_name)) do |assignment|
    assignment.crew_role = roles[role]
    assignment.starts_on = projects[project].starts_on
  end
end

# Demo certificates are dated relative to today, so finding them by completed_on would add a
# second, shifted copy of each (superseding the first) on every later day the seeds run.
# Only members who have no certificates yet get them.
already_certified = Certificate.where(crew_member: crew.values).distinct.pluck(:crew_member_id).to_set

# [first name, code, completed days ago, expires days from today (nil = never), extra attributes]
[
  [ "Juan", "OSHA30", 700, nil, { certificate_number: "30-1234567", issued_by: "Example Safety Training LLC" } ],
  [ "Juan", "FIRSTAID", 800, -70, { issued_by: "American Red Cross" } ], # superseded by the next one
  [ "Juan", "FIRSTAID", 60, 670, { issued_by: "American Red Cross" } ],
  [ "Juan", "FLAGGER", 1080, 12, {} ],                                    # expiring
  [ "Juan", "CLIMBER", 300, 60, { expires_on_source: :printed } ],        # lapses on the tower project
  [ "Juan", "RFSAFETY", 200, nil, {} ],
  [ "Maria", "OSHA30", 1200, nil, {} ],
  [ "Maria", "FIRSTAID", 735, -5, {} ],                                   # expired
  [ "Maria", "OSHA10", 2000, nil, {} ],
  [ "Li", "OSHA30", 365, nil, {} ],
  [ "Li", "FLAGGER", 730, 500, { expires_on_source: :printed, source: :import, verified_by: manager, verified_at: Time.current } ],
  [ "Li", "FIRSTAID", 1100, -400, {} ],                                   # long expired
  [ "David", "OSHA30", 90, nil, {} ],
  [ "David", "FLAGGER", 400, 695, {} ],
  [ "David", "FIRSTAID", 100, 630, {} ],
  [ "David", "CDLA", 1800, 25, { certificate_number: "CO-123456789", expires_on_source: :printed } ],
  [ "Ana", "OSHA10", 400, nil, {} ],
  [ "Ana", "FIRSTAID", 300, 430, {} ],
  [ "Ana", "AERIAL", 1000, 95, {} ],
  [ "Tom", "OSHA30", 50, nil, {} ],
  [ "Sam", "OSHA30", 900, nil, {} ]
].each do |first_name, code, completed_ago, expires_in, extra|
  member = crew.fetch(first_name)
  next if already_certified.include?(member.id)

  Certificate.find_or_create_by!(crew_member: member, certificate_type: types.fetch(code),
    completed_on: today - completed_ago) do |certificate|
    certificate.expires_on = today + expires_in if expires_in
    certificate.assign_attributes(extra)
  end
end
