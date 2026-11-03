# The requirements editor: a grid of certificate types (rows) by "Everyone" plus each
# crew role (columns), and "copy requirements from another project".
class ProjectRequirementsController < ApplicationController
  require_role :editor
  before_action :set_project

  def edit
    requirements = @project.project_requirements.to_a
    @requirements_by_key = requirements.index_by { |requirement| requirement_key(requirement) }
    # Active types, plus retired ones still required here so saving never drops them unseen.
    @certificate_types = CertificateType.active.or(CertificateType.where(id: requirements.map(&:certificate_type_id)))
      .ordered.to_a
    @crew_roles = CrewRole.ordered.to_a
    @requirement_counts = ProjectRequirement.where.not(project_id: @project.id).group(:project_id).count
    @copy_sources = Project.where(id: @requirement_counts.keys).ordered.to_a
  end

  def update
    pairs = Projects::UpdateRequirements.parse(params.expect(requirement_keys: []))
    result = Projects::UpdateRequirements.new(@project, pairs).call

    notice = if result.changed?
      "Requirements saved: #{result.added} added, #{result.removed} removed."
    else
      "No changes to requirements."
    end
    redirect_to @project, notice: notice
  end

  def copy
    source = Project.where.not(id: @project.id).find_by(id: params[:source_project_id])
    return redirect_to(edit_project_requirements_path(@project), alert: "Choose a project to copy from.") unless source

    result = Projects::CopyRequirements.new(@project, source).call
    redirect_to edit_project_requirements_path(@project), notice: copy_notice(result, source)
  end

  private
    def set_project
      @project = Project.find(params.expect(:project_id))
    end

    def requirement_key(requirement)
      Projects::UpdateRequirements.key(requirement.certificate_type_id, requirement.crew_role_id)
    end

    def copy_notice(result, source)
      details = []
      details << "#{result.already_present} already here" if result.already_present.positive?
      details << "#{helpers.pluralize(result.skipped_inactive, 'retired type')} skipped" if result.skipped_inactive.positive?
      text = "Copied #{helpers.pluralize(result.added, 'requirement')} from #{source.display_name}"
      details.any? ? "#{text} (#{details.join(', ')})." : "#{text}."
    end
end
