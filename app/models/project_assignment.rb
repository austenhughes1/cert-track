class ProjectAssignment < ApplicationRecord
  belongs_to :project
  belongs_to :crew_member
  belongs_to :crew_role, optional: true # role on this project; nil falls back to the member's role

  validates :crew_member_id, uniqueness: { scope: :project_id, message: "is already assigned to this project" }
  validate :ends_on_not_before_starts_on

  # Assignments still on the crew as of today: no end date, or ending today or later.
  # Future start dates count, so gaps show before someone reaches the site. A closed
  # project keeps every assignment: its matrix is the record of who worked on it.
  # Joins projects.
  scope :on_crew, ->(today: Date.current) {
    joins(:project).where("project_assignments.ends_on IS NULL OR project_assignments.ends_on >= ? OR projects.status = ?",
      today, Project.statuses.fetch("closed"))
  }

  def effective_role
    crew_role || crew_member&.crew_role
  end

  def effective_role_id
    crew_role_id || crew_member&.crew_role_id
  end

  # Distinct CertificateTypes this person needs on this project.
  def required_certificate_types
    project.requirements_for(effective_role_id).map(&:certificate_type).uniq
  end

  private
    def ends_on_not_before_starts_on
      return if starts_on.blank? || ends_on.blank? || ends_on >= starts_on

      errors.add(:ends_on, "can't be before the start date")
    end
end
