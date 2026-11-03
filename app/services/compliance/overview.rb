module Compliance
  # Compliance across many projects (the dashboard, digests, crew filters). All the
  # reports share one ProjectReport::Dataset, so it runs the same handful of queries
  # for 1 project or 100. Reports keep the order the projects were given in; pass
  # Project.active.ordered for name order.
  class Overview
    attr_reader :today

    def initialize(projects, today: Date.current)
      @projects = projects
      @today = today
    end

    def projects
      @projects = @projects.to_a
    end

    # Array<ProjectReport>, one per project.
    def reports
      @reports ||= ProjectReport.for_projects(projects, today: today)
    end

    # project: a Project or its id.
    def report_for(project)
      project_id = project.respond_to?(:id) ? project.id : project
      reports.find { |report| report.project.id == project_id }
    end

    # Same shape as ProjectReport#summary, summed over every project.
    def totals
      @totals ||= Compliance::STATUSES.index_with(0).tap do |totals|
        reports.each { |report| report.summary.each { |status, count| totals[status] += count } }
      end
    end

    # Hash{crew_member_id => most severe status over every required cell on every
    # project}. Members with nothing required anywhere are left out.
    def worst_status_by_crew_member
      @worst_status_by_crew_member ||= rows.group_by { |row| row.crew_member.id }.filter_map do |member_id, member_rows|
        worst = Compliance.worst(member_rows.flat_map { |row| row.required_cells.map(&:status) })
        [ member_id, worst ] if worst
      end.to_h
    end

    # Set of crew member ids with at least one cell of status on any project.
    def crew_member_ids_with(status)
      status = status.to_s
      rows.each_with_object(Set.new) do |row, ids|
        ids << row.crew_member.id if row.cells.any? { |cell| cell.status == status }
      end
    end

    # Every missing or expired cell across the projects.
    def gaps
      @gaps ||= reports.flat_map(&:gaps)
    end

    private
      def rows
        @rows ||= reports.flat_map(&:rows)
      end
  end
end
