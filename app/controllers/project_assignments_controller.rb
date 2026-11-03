# Crew on a project: add active members, override their role for this project, set
# dates, remove. Failed saves re-render the list with the errors on the affected form.
class ProjectAssignmentsController < ApplicationController
  DUPLICATE_MESSAGE = "is already assigned to this project".freeze

  require_role :editor, except: :index
  before_action :set_project
  before_action :set_assignment, only: %i[update destroy]

  def index
    @new_assignment = ProjectAssignment.new(project: @project)
    load_page
  end

  def create
    @new_assignment = ProjectAssignment.new(create_params.merge(project: @project))

    if @new_assignment.crew_member&.active? == false
      @new_assignment.errors.add(:crew_member, "is inactive; reactivate them before assigning")
      render_page_with_errors
    elsif @new_assignment.save
      redirect_to project_assignments_path(@project), notice: "Assigned #{@new_assignment.crew_member.display_name}."
    else
      render_page_with_errors
    end
  rescue ActiveRecord::RecordNotUnique
    @new_assignment.errors.add(:crew_member_id, DUPLICATE_MESSAGE)
    render_page_with_errors
  end

  def update
    if @assignment.update(update_params)
      redirect_to project_assignments_path(@project), notice: "Saved #{@assignment.crew_member.display_name}."
    else
      @failed_assignment = @assignment
      @new_assignment = ProjectAssignment.new(project: @project)
      render_page_with_errors
    end
  end

  def destroy
    @assignment.destroy!
    redirect_to project_assignments_path(@project), status: :see_other,
      notice: "Removed #{@assignment.crew_member.display_name} from #{@project.display_name}."
  end

  private
    def set_project
      @project = Project.find(params.expect(:project_id))
    end

    def set_assignment
      @assignment = @project.project_assignments.includes(:crew_member).find(params.expect(:id))
    end

    def create_params
      params.expect(project_assignment: %i[crew_member_id crew_role_id starts_on ends_on])
    end

    def update_params
      params.expect(project_assignment: %i[crew_role_id starts_on ends_on])
    end

    def load_page
      # Preloaded so each row's required types come from memory (Project#requirements_for).
      ActiveRecord::Associations::Preloader.new(records: [ @project ], associations: { project_requirements: :certificate_type }).call
      @assignments = @project.project_assignments.joins(:crew_member).merge(CrewMember.ordered)
        .includes(:crew_role, crew_member: :crew_role).to_a
      @assignments.map! { |assignment| assignment.id == @failed_assignment.id ? @failed_assignment : assignment } if @failed_assignment
      @available_members = CrewMember.active.where.not(id: @project.project_assignments.select(:crew_member_id))
        .includes(:crew_role).ordered.to_a
      @crew_roles = CrewRole.ordered.to_a
    end

    def render_page_with_errors
      load_page
      render :index, status: :unprocessable_entity
    end
end
