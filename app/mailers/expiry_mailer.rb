# Expiry emails. Digests go to users with receives_digest (see User.digest_recipients);
# crew notices go to an opted-in crew member about their own certificate only.
#
#   ExpiryMailer.with(user:, items:).daily_digest                  # items: Array<Notifications::DigestItem>
#   ExpiryMailer.with(user:, expiring:, gaps:).weekly_digest       # expiring: DigestItems; gaps: Array<Compliance::ProjectReport::Gap>
#   ExpiryMailer.with(crew_member:, certificate:, threshold:).crew_notice
#
# daily_digest also takes test: true (adds "[Test]" and a banner) and sample: true (the
# banner says the data is made up), used by UsersController#send_test_digest.
#
# Items hold Active Record objects inside Data structs, which Active Job can't serialize:
# deliver these with deliver_now.
class ExpiryMailer < ApplicationMailer
  NO_PROJECT = "Not on an active project".freeze
  DATE_FORMAT = "%b %-d, %Y".freeze # "Dec 1, 2026"

  helper do
    def email_date(date)
      date&.strftime(ExpiryMailer::DATE_FORMAT)
    end

    # "30 days", "7 days", "Expired 5 days ago"
    def threshold_label(item)
      if item.threshold.to_s == "expired"
        ago = -item.days_left.to_i
        ago.positive? ? "Expired #{pluralize(ago, "day")} ago" : "Expired"
      else
        "#{ExpiryNotification::THRESHOLD_DAYS.fetch(item.threshold.to_s)} days"
      end
    end

    # "Flagger, expires Dec 1, 2026 (in 29 days), needed on 2417 and 2420"
    def item_line(item)
      days_left = item.days_left || (item.expires_on - Date.current).to_i
      [ item.certificate_type.name, expiry_phrase(item.expires_on, days_left), needed_on(item.projects) ].compact.join(", ")
    end

    def expiry_phrase(expires_on, days_left)
      date = email_date(expires_on)
      case days_left
      when ...0 then "expired #{date}"
      when 0 then "expires #{date} (today)"
      when 1 then "expires #{date} (tomorrow)"
      else "expires #{date} (in #{days_left} days)"
      end
    end

    def needed_on(projects)
      "needed on #{projects.map { |project| project.code.presence || project.name }.to_sentence}" if projects.present?
    end

    # Badge colours for email (inline styles; no Tailwind in mail clients).
    def threshold_style(threshold)
      colors = case threshold.to_s
      when "expired" then "background-color:#fee2e2;color:#991b1b;"
      when "d7" then "background-color:#ffedd5;color:#9a3412;"
      when "d30" then "background-color:#fef3c7;color:#92400e;"
      else "background-color:#e0e7ff;color:#3730a3;"
      end
      "#{colors}display:inline-block;padding:1px 8px;border-radius:9999px;font-size:12px;font-weight:600;white-space:nowrap;"
    end

    def crew_member_link(crew_member, style: "color:#1d4ed8;font-weight:600;")
      return crew_member.display_name unless crew_member.persisted?

      link_to crew_member.display_name, crew_member_url(crew_member), style: style
    end

    def crew_member_url_or_nil(crew_member)
      crew_member_url(crew_member) if crew_member.persisted?
    end

    # "Missing", or "Expired Oct 28, 2026"
    def gap_status_text(gap)
      expires_on = gap.certificate&.expires_on
      gap.status.to_s == "expired" && expires_on ? "Expired #{email_date(expires_on)}" : Compliance.label(gap.status)
    end

    def project_heading(project)
      project ? project.display_name : ExpiryMailer::NO_PROJECT
    end

    def project_compliance_url_or_nil(project)
      project_compliance_url(project) if project&.persisted?
    end
  end

  def daily_digest
    @user = params.fetch(:user)
    @items = Array(params.fetch(:items))
    @test = params[:test].present?
    @sample = params[:sample].present?
    @groups = group_by_project_and_person(@items)

    subject = "CertTrack: #{count_of(@items.size, "certificate")} #{@items.one? ? "needs" : "need"} attention"
    mail to: @user.email_address, subject: @test ? "[Test] #{subject}" : subject
  end

  def weekly_digest
    @user = params.fetch(:user)
    @expiring = Array(params.fetch(:expiring)).sort_by { |item| [ item.expires_on, *name_key(item.crew_member) ] }
    @expired_count = @expiring.count { |item| item.threshold.to_s == "expired" }
    @gaps = Array(params.fetch(:gaps))
    @gap_groups = group_gaps(@gaps)
    @today = Date.current

    mail to: @user.email_address, subject: weekly_subject
  end

  # No-op (nothing is delivered) when the crew member has no email address. Replies go to
  # OFFICE_EMAIL, a monitored inbox (config/deploy.yml). Never to the From address: the
  # notify subdomain only sends. Without OFFICE_EMAIL there is no Reply-To and the notice
  # doesn't ask the crew member to reply.
  def crew_notice
    @crew_member = params.fetch(:crew_member)
    @certificate = params.fetch(:certificate)
    @threshold = params.fetch(:threshold).to_s
    raise ArgumentError, "certificate belongs to another crew member" if @certificate.crew_member_id != @crew_member.id
    return if @crew_member.email.blank?

    @certificate_type = @certificate.certificate_type
    @days_left = @certificate.days_until_expiry
    @office_email = ENV["OFFICE_EMAIL"].presence

    verb = @days_left&.negative? ? "expired" : "expires"
    mail to: email_address_with_name(@crew_member.email, @crew_member.display_name),
      reply_to: @office_email,
      subject: "Your #{@certificate_type.name} certificate #{verb} #{@certificate.expires_on&.strftime(DATE_FORMAT)}"
  end

  # Unsaved stand-ins for previews and for a test digest when nothing is near expiry.
  # Unsaved records render without links.
  class << self
    def sample_items(today: Date.current)
      sample = sample_records
      [
        sample_item(sample[:alex], sample[:flagger], today + 29, today: today, projects: [ sample[:project] ]),
        sample_item(sample[:alex], sample[:first_aid], today + 6, today: today, projects: [ sample[:project] ]),
        sample_item(sample[:sam], sample[:first_aid], today - 3, today: today, projects: [])
      ]
    end

    def sample_gaps(today: Date.current)
      sample = sample_records
      expired = Certificate.new(crew_member: sample[:sam], certificate_type: sample[:first_aid],
        completed_on: today - 2.years - 3.days, expires_on: today - 3)
      [
        Compliance::ProjectReport::Gap.new(project: sample[:project], crew_member: sample[:alex],
          certificate_type: sample[:climber], status: "missing", certificate: nil),
        Compliance::ProjectReport::Gap.new(project: sample[:project], crew_member: sample[:sam],
          certificate_type: sample[:first_aid], status: "expired", certificate: expired)
      ]
    end

    private
      def sample_records
        {
          flagger: CertificateType.new(name: "Flagger", code: "FLAGGER", validity_months: 36, position: 1),
          first_aid: CertificateType.new(name: "First Aid/CPR/AED", code: "FIRSTAID", validity_months: 24, position: 2),
          climber: CertificateType.new(name: "Authorized Climber", code: "CLIMBER", validity_months: 24, position: 3),
          project: Project.new(name: "Sample Tower Upgrade", code: "0000", status: :active),
          alex: CrewMember.new(first_name: "Alex", last_name: "Example"),
          sam: CrewMember.new(first_name: "Sam", last_name: "Sample")
        }
      end

      def sample_item(crew_member, certificate_type, expires_on, today:, projects:)
        certificate = Certificate.new(crew_member: crew_member, certificate_type: certificate_type,
          completed_on: expires_on.advance(months: -certificate_type.validity_months), expires_on: expires_on)
        days_left = (expires_on - today).to_i
        Notifications::DigestItem.new(
          certificate: certificate, crew_member: crew_member, certificate_type: certificate_type,
          threshold: ExpiryNotification.threshold_for(days_left), expires_on: expires_on, days_left: days_left, projects: projects)
      end
  end

  private
    # [[project_or_nil, [[crew_member, items], ...]], ...]: projects by name, "no active
    # project" last; people by last name; each person's items most urgent first. An item
    # needed on two projects appears under both.
    def group_by_project_and_person(items)
      by_project = Hash.new { |hash, key| hash[key] = [] }
      items.each do |item|
        (item.projects.presence || [ nil ]).each { |project| by_project[project] << item }
      end

      by_project
        .sort_by { |project, _| project ? [ 0, project.display_name.downcase ] : [ 1, "" ] }
        .map { |project, project_items| [ project, group_by_person(project_items) ] }
    end

    def group_by_person(items)
      items.group_by(&:crew_member)
        .sort_by { |crew_member, _| name_key(crew_member) }
        .map { |crew_member, person_items| [ crew_member, person_items.sort_by(&:expires_on) ] }
    end

    # [[project, gaps], ...] by project name; gaps by person, then type position.
    def group_gaps(gaps)
      gaps.group_by(&:project)
        .sort_by { |project, _| project.display_name.downcase }
        .map do |project, project_gaps|
          [ project, project_gaps.sort_by { |gap| [ *name_key(gap.crew_member), gap.certificate_type.position || Float::INFINITY, gap.certificate_type.name ] } ]
        end
    end

    def weekly_subject
      return "CertTrack weekly: all clear" if @expiring.empty? && @gaps.empty?

      expiring_soon = @expiring.size - @expired_count
      parts = []
      parts << "#{expiring_soon} expiring soon" if expiring_soon.positive?
      parts << "#{@expired_count} expired" if @expired_count.positive?
      parts << "#{count_of(@gaps.size, "gap")} on active projects" if @gaps.any?
      "CertTrack weekly: #{parts.join(", ")}"
    end

    def name_key(crew_member)
      [ crew_member.last_name.downcase, crew_member.first_name.downcase ]
    end

    def count_of(count, noun)
      "#{count} #{noun.pluralize(count)}"
    end
end
