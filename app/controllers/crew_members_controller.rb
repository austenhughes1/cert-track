class CrewMembersController < ApplicationController
  INDEX_LIMIT = 100 # no pagination gem; the page says "showing first 100"
  STATUS_FILTERS = %w[expired missing expiring lapses_on_project].freeze
  PROJECT_STATUS_ORDER = %w[active planned closed].freeze

  require_role :editor, except: %i[index show]
  before_action :set_crew_member, only: %i[show edit update destroy]

  # Filters (all optional, GET params): q (typo-tolerant name search), active ("" = active
  # only, "inactive", "all"), employer, crew_role_id (an id or "none"), status (one of
  # STATUS_FILTERS, across active projects).
  def index
    @filters = index_filters
    @overview = Compliance::Overview.new(Project.active, today: Date.current)

    members = filtered_crew_members
    @total_count = members.count
    @crew_members = members.includes(:crew_role).limit(INDEX_LIMIT).to_a
    @current_certificate_counts = Certificate.current.where(crew_member_id: @crew_members.map(&:id)).group(:crew_member_id).count
    @worst_statuses = @overview.worst_status_by_crew_member
    @employers = CrewMember.employer_names
    @crew_roles = CrewRole.ordered.to_a
  end

  def show
    @today = Date.current
    @current_certificates = @crew_member.current_certificates.includes(:certificate_type).with_attached_files
      .sort_by { |certificate| certificate_type_sort_key(certificate.certificate_type) }
    @superseded_count = @crew_member.certificates.superseded.count
    @show_history = params[:history] == "1"
    if @show_history
      @superseded_certificates = @crew_member.certificates.superseded.includes(:certificate_type).with_attached_files.chronological.to_a
    end

    @assignments = @crew_member.project_assignments.includes(:project, :crew_role).to_a
      .sort_by { |assignment| project_sort_key(assignment.project) }
    # Closed projects are listed without compliance, and reports leave inactive members out.
    # One shared dataset keeps the query count flat however many projects the member is on.
    tracked = @crew_member.active? ? @assignments.map(&:project).reject(&:closed?) : []
    @project_rows = Compliance::ProjectReport.for_projects(tracked, today: @today).to_h do |report|
      [ report.project.id, report.row_for(@crew_member) ]
    end
  end

  def new
    @crew_member = CrewMember.new
  end

  def create
    @crew_member = CrewMember.new(crew_member_params)

    if @crew_member.save
      redirect_to @crew_member, notice: "Added #{@crew_member.display_name}."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  # Also serves the Deactivate / Reactivate buttons (crew_member[active]=0/1).
  def update
    if @crew_member.update(crew_member_params)
      redirect_to @crew_member, notice: update_notice, status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # History is never deleted: certificates and assignments restrict the delete. A member
  # with neither is deleted outright; anyone else is deactivated instead.
  def destroy
    if @crew_member.certificates.none? && @crew_member.project_assignments.none? && @crew_member.destroy
      redirect_to crew_members_path, notice: "Deleted #{@crew_member.display_name}.", status: :see_other
    elsif @crew_member.reload.update(active: false)
      redirect_to @crew_member, status: :see_other,
        notice: "#{@crew_member.display_name} has certificates or project assignments, so they were deactivated instead of deleted."
    else
      redirect_to @crew_member, alert: @crew_member.errors.full_messages.to_sentence, status: :see_other
    end
  end

  private
    def set_crew_member
      @crew_member = CrewMember.includes(:crew_role).find(params.expect(:id))
    end

    def crew_member_params
      attributes = params.expect(crew_member: %i[first_name last_name preferred_name name_aliases email phone
        employer crew_role_id active expiry_emails_opt_in notes])
      # The form sends aliases as a textarea, one per line; the model cleans the array.
      attributes[:name_aliases] = attributes[:name_aliases].to_s.split(/\r?\n/) if attributes.key?(:name_aliases)
      attributes
    end

    def index_filters
      filters = params.permit(:q, :active, :employer, :crew_role_id, :status).to_h.symbolize_keys
      filters[:q] = filters[:q].to_s.squish
      filters[:active] = filters[:active].presence_in(%w[inactive all]).to_s
      filters[:status] = filters[:status].presence_in(STATUS_FILTERS).to_s
      filters[:employer] = filters[:employer].to_s
      # "abc" would cast to nil and match role-less members, so only ids and "none" count.
      filters[:crew_role_id] = filters[:crew_role_id].to_s.then { |id| id == "none" || id.match?(/\A\d+\z/) ? id : "" }
      filters
    end

    def filtered_crew_members
      members = CrewMember.all
      members = case @filters[:active]
      when "all" then members
      when "inactive" then members.inactive
      else members.active
      end
      members = members.where(employer: @filters[:employer]) if @filters[:employer].present?
      if @filters[:crew_role_id] == "none"
        members = members.where(crew_role_id: nil)
      elsif @filters[:crew_role_id].present?
        members = members.where(crew_role_id: @filters[:crew_role_id])
      end
      members = members.where(id: @overview.crew_member_ids_with(@filters[:status]).to_a) if @filters[:status].present?
      @filters[:q].present? ? members.search(@filters[:q]) : members.ordered
    end

    # Active projects first, then planned, then closed; by name within each.
    def project_sort_key(project)
      [ PROJECT_STATUS_ORDER.index(project.status) || PROJECT_STATUS_ORDER.size, project.name.downcase, project.id ]
    end

    def certificate_type_sort_key(type)
      [ type.position.nil? ? 1 : 0, type.position.to_i, type.name.downcase ]
    end

    def update_notice
      if @crew_member.saved_change_to_active?
        @crew_member.active? ? "Reactivated #{@crew_member.display_name}." : "Deactivated #{@crew_member.display_name}. Their history is kept."
      else
        "Saved #{@crew_member.display_name}."
      end
    end
end
