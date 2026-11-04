class ProjectsController < ApplicationController
  # Index tabs: param value => statuses shown. "open" is the default.
  STATUS_FILTERS = {
    "open" => %w[planned active],
    "planned" => %w[planned],
    "active" => %w[active],
    "closed" => %w[closed],
    "all" => Project.statuses.keys
  }.freeze

  require_role :editor, except: %i[index show]
  before_action :set_project, only: %i[show edit update destroy]

  def index
    @status_filter = STATUS_FILTERS.key?(params[:status]) ? params[:status] : "open"
    @status_counts = Project.group(:status).count
    @projects = Project.where(status: STATUS_FILTERS.fetch(@status_filter)).ordered.to_a
    @reports = Compliance::Overview.new(@projects, today: Date.current).reports.index_by { |report| report.project.id }
  end

  def show
    @requirements_by_type = @project.project_requirements.includes(:certificate_type, :crew_role).to_a
      .group_by(&:certificate_type)
      .sort_by { |type, _| [ type.position.nil? ? 1 : 0, type.position.to_i, type.name.downcase ] }
    @assignments = @project.project_assignments.joins(:crew_member).merge(CrewMember.ordered)
      .includes(:crew_role, crew_member: :crew_role).to_a
    @report = Compliance::ProjectReport.new(@project, today: Date.current)
  end

  def new
    @project = Project.new(status: :planned)
  end

  def create
    @project = Project.new(project_params)

    if @project.save
      redirect_to @project, notice: "Created #{@project.display_name}. Next, choose its required certificates."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @project.update(project_params)
      notice = @project.saved_change_to_status? ? "#{@project.display_name} is now #{@project.status}." : "Saved #{@project.display_name}."
      redirect_to @project, notice: notice
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Projects with crew or requirements are history; close them instead. The row lock
  # blocks assignments and requirements from being added while we check and delete.
  def destroy
    deleted = @project.with_lock do
      # Packet builds are the lasting record of what was sent, so they keep the project too.
      next false if @project.project_assignments.exists? || @project.project_requirements.exists? || @project.packet_builds.exists?

      @project.destroy!
    end

    if deleted
      redirect_to projects_path, notice: "Deleted #{@project.display_name}.", status: :see_other
    else
      redirect_to @project, status: :see_other,
        alert: "#{@project.display_name} has crew assignments, requirements or past packets, so it can't be deleted. Close it instead to keep its history."
    end
  end

  private
    def set_project
      @project = Project.find(params.expect(:id))
    end

    def project_params
      params.expect(project: %i[name code client location starts_on ends_on status])
    end
end
