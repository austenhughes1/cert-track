class CrewRolesController < ApplicationController
  require_role :editor, except: :index
  before_action :set_crew_role, only: %i[edit update destroy]

  def index
    @crew_roles = CrewRole.ordered.to_a
    @member_counts = CrewMember.where.not(crew_role_id: nil).group(:crew_role_id).count
    @requirement_counts = ProjectRequirement.where.not(crew_role_id: nil).group(:crew_role_id).count
    @assignment_counts = ProjectAssignment.where.not(crew_role_id: nil).group(:crew_role_id).count
  end

  def new
    @crew_role = CrewRole.new
  end

  def create
    @crew_role = CrewRole.new(crew_role_params)

    if @crew_role.save
      redirect_to crew_roles_path, notice: "Added the #{@crew_role.name} role."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @crew_role.update(crew_role_params)
      redirect_to crew_roles_path, notice: "Saved the #{@crew_role.name} role.", status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Roles in use by members, requirements or assignments can't be deleted (restrict_with_error).
  def destroy
    if @crew_role.destroy
      redirect_to crew_roles_path, notice: "Deleted the #{@crew_role.name} role.", status: :see_other
    else
      redirect_to crew_roles_path, status: :see_other,
        alert: "Can't delete the #{@crew_role.name} role: #{@crew_role.errors.full_messages.to_sentence.downcase_first}."
    end
  end

  private
    def set_crew_role
      @crew_role = CrewRole.find(params.expect(:id))
    end

    def crew_role_params
      params.expect(crew_role: %i[name])
    end
end
