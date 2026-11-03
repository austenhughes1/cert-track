# One master-list type required on a project, for everyone (crew_role nil) or one role.
class ProjectRequirement < ApplicationRecord
  belongs_to :project
  belongs_to :certificate_type
  belongs_to :crew_role, optional: true

  validates :certificate_type_id, uniqueness: { scope: %i[project_id crew_role_id], message: "is already required for that role" }

  scope :for_everyone, -> { where(crew_role_id: nil) }
  # Requirements applying to role (CrewRole, id or nil): everyone's plus that role's.
  scope :for_role, ->(role) { where(crew_role_id: [ nil, role.is_a?(CrewRole) ? role.id : role ].uniq) }

  def everyone?
    crew_role_id.nil?
  end

  def applies_to?(role_id)
    crew_role_id.nil? || crew_role_id == role_id
  end
end
