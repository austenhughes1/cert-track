# "/": compliance totals across active projects, the import review queue, certificates that are
# confirmed fake, flagged for review or need a check (Phase 3b), the next certificates to expire
# and the active-project list. Every role can see it.
class DashboardController < ApplicationController
  UPCOMING_LIMIT = 20

  def show
    @today = Date.current
    @type_count = CertificateType.active.count
    @timed_type_count = CertificateType.active.where.not(validity_months: nil).count
    @has_crew = CrewMember.exists?
    @has_projects = Project.exists?

    @overview = Compliance::Overview.new(Project.active.ordered, today: @today)
    @reports = @overview.reports # in the given (name) order
    @review_count = ImportItem.needs_review.count
    @verification_counts = verification_counts
    @upcoming = upcoming_expirations
    @needed_on = projects_needing(@upcoming)
  end

  private
    # { "fake" => n, "flagged" => n, "needs_check" => n }: current certificates of active crew (the
    # verification list's), in one grouped query.
    def verification_counts
      Certificate.current.joins(:crew_member).merge(CrewMember.active).authenticity_review_counts
    end

    # Current certificates of active crew that haven't expired yet, soonest first.
    def upcoming_expirations
      Certificate.current
        .where(expires_on: @today..)
        .joins(:crew_member).merge(CrewMember.active)
        .preload(:crew_member, :certificate_type)
        .order(:expires_on, :id)
        .limit(UPCOMING_LIMIT)
        .to_a
    end

    # { certificate_id => [active projects that require this type of this person] }.
    # Reuses the overview's already-loaded reports, so it adds no queries.
    def projects_needing(certificates)
      certificates.to_h do |certificate|
        projects = @reports.filter_map do |report|
          cell = report.row_for(certificate.crew_member_id)&.cell_for(certificate.certificate_type_id)
          report.project if cell&.required?
        end
        [ certificate.id, projects ]
      end
    end
end
