module Compliance
  # The compliance matrix for one project: rows are the assignments of active crew
  # members that haven't ended (ProjectAssignment.on_crew), columns are every type any
  # requirement on the project names, and each cell holds the status of that person's
  # current certificate for that type.
  #
  # Lazy and memoized. Building a report runs a fixed number of queries no matter how
  # many people or types the project has (see Dataset). Inactive crew members are left
  # out entirely: they are not on the crew any more, so they are neither gaps nor rows.
  # A column type that does not apply to a person's effective role (the assignment's
  # role, else the member's role) is a "not_required" cell with no certificate.
  class ProjectReport
    NOT_REQUIRED = "not_required".freeze
    GAP_STATUSES = %w[missing expired].freeze
    CSV_HEADER = [ "Last name", "First name", "Role", "Employer" ].freeze

    Cell = Data.define(:certificate_type, :status, :certificate, :expires_on) do
      def required?
        status != NOT_REQUIRED
      end

      def gap?
        GAP_STATUSES.include?(status)
      end

      def days_until_expiry(today: Date.current)
        (expires_on - today).to_i if expires_on
      end
    end

    Row = Data.define(:assignment, :crew_member, :role, :cells) do
      # certificate_type: a CertificateType or its id. nil only for a type that is not a column.
      def cell_for(certificate_type)
        type_id = certificate_type.respond_to?(:id) ? certificate_type.id : certificate_type
        cells.find { |cell| cell.certificate_type.id == type_id }
      end

      def required_cells
        cells.select(&:required?)
      end

      def gaps
        cells.select(&:gap?)
      end

      # Most severe status among the required cells; nil when nothing is required.
      def worst_status
        Compliance.worst(required_cells.map(&:status))
      end
    end

    Gap = Data.define(:project, :crew_member, :certificate_type, :status, :certificate)

    attr_reader :project, :today

    # Reports for many projects that share one Dataset, so the query count stays
    # constant however many projects there are.
    def self.for_projects(projects, today: Date.current)
      projects = projects.to_a
      dataset = Dataset.new(projects, today: today)
      projects.map { |project| new(project, today: today, dataset: dataset) }
    end

    # dataset: internal, used by .for_projects.
    def initialize(project, today: Date.current, dataset: nil)
      @project = project
      @today = today
      @dataset = dataset
    end

    # Array<CertificateType>, ordered by position (nulls last), then name.
    def columns
      @columns ||= dataset.columns_for(project.id)
    end

    # Array<Row>, one per assignment still on the crew of an active crew member, by last
    # name, first name.
    def rows
      @rows ||= dataset.assignments_for(project.id).map { |assignment| build_row(assignment) }
    end

    # crew_member: a CrewMember or its id.
    def row_for(crew_member)
      member_id = crew_member.respond_to?(:id) ? crew_member.id : crew_member
      rows_by_member_id[member_id]
    end

    # Counts over required cells, keyed by every status in Compliance::STATUSES.
    def summary
      @summary ||= Compliance::STATUSES.index_with(0).tap do |counts|
        rows.each { |row| row.required_cells.each { |cell| counts[cell.status] += 1 } }
      end
    end

    # Missing and expired cells, in row then column order.
    def gaps
      @gaps ||= rows.flat_map do |row|
        row.gaps.map do |cell|
          Gap.new(project: project, crew_member: row.crew_member, certificate_type: cell.certificate_type,
            status: cell.status, certificate: cell.certificate)
        end
      end
    end

    # True when no required cell is missing or expired.
    def compliant?
      gaps.empty?
    end

    # The current certificates shown in required cells (packet building, file preloads).
    def certificates
      @certificates ||= rows.flat_map { |row| row.cells.filter_map(&:certificate) }
    end

    # One line per row: name, role, employer, then one column per type code holding
    # "valid (2027-03-14)", "expired (2025-01-02)", "missing", "not required" and so on.
    def to_csv
      lines = [ CSV_HEADER + columns.map(&:code) ]
      rows.each do |row|
        member = row.crew_member
        lines << [ member.last_name, member.first_name, row.role&.name, member.employer ] +
          row.cells.map { |cell| csv_value(cell) }
      end
      lines.map { |fields| csv_line(fields) }.join
    end

    # Same file-safe slug as the packet zip, e.g. "2417-compliance-2026-11-02.csv".
    def csv_filename
      "#{PacketBuilder.slug_for(project)}-compliance-#{today.iso8601}.csv"
    end

    private
      def dataset
        @dataset ||= Dataset.new([ project ], today: today)
      end

      def rows_by_member_id
        @rows_by_member_id ||= rows.index_by { |row| row.crew_member.id }
      end

      def build_row(assignment)
        assignment.association(:project).target = project
        member = assignment.crew_member
        required = dataset.required_certificate_ids_for(assignment.id)

        cells = columns.map do |type|
          if required.key?(type.id)
            certificate = dataset.certificate(required[type.id])
            link_certificate(certificate, member, type) if certificate
            Cell.new(certificate_type: type, certificate: certificate, expires_on: certificate&.expires_on,
              status: Compliance.status_for(certificate, today: today, project_ends_on: project.ends_on))
          else
            Cell.new(certificate_type: type, status: NOT_REQUIRED, certificate: nil, expires_on: nil)
          end
        end

        Row.new(assignment: assignment, crew_member: member, role: assignment.crew_role || member.crew_role, cells: cells)
      end

      # Saves callers a query per certificate when they follow these associations.
      def link_certificate(certificate, member, type)
        certificate.association(:crew_member).target = member
        certificate.association(:certificate_type).target = type
      end

      def csv_value(cell)
        text = cell.status.tr("_", " ")
        cell.expires_on ? "#{text} (#{cell.expires_on.iso8601})" : text
      end

      # Prefixes values a spreadsheet would run as a formula (CSV injection). csv is a
      # bundled gem since Ruby 3.4 and not in the Gemfile yet, so there is no require:
      # Bundler loads it once it is added, and until then a minimal RFC 4180 writer
      # produces the same output.
      def csv_line(fields)
        fields = fields.map { |field| field.to_s.match?(/\A[=+\-@\t\r]/) ? "'#{field}" : field }
        return ::CSV.generate_line(fields) if defined?(::CSV)

        fields.map { |field| csv_field(field) }.join(",") + "\n"
      end

      def csv_field(field)
        return "" if field.nil?

        text = field.to_s
        text.empty? || text.match?(/[",\r\n]/) ? %("#{text.gsub('"', '""')}") : text
      end
  end
end
