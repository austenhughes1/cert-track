class Project < ApplicationRecord
  enum :status, { planned: 0, active: 1, closed: 2 }, default: :active, validate: true

  has_many :project_requirements, dependent: :delete_all
  has_many :required_certificate_types, -> { distinct }, through: :project_requirements, source: :certificate_type
  has_many :project_assignments, dependent: :delete_all
  has_many :crew_members, through: :project_assignments
  has_one_attached :packet # zip built by a background job; see packet_built_at

  normalizes :name, :client, :location, with: ->(value) { value.squish.presence }
  normalizes :code, with: ->(code) { code.strip.upcase.presence }

  validates :name, presence: true
  validates :code, uniqueness: true, allow_nil: true
  validate :ends_on_not_before_starts_on

  scope :ordered, -> { order(:name, :id) }

  # "2417 · Tower Upgrade", or the name alone when there is no code.
  def display_name
    code.present? ? "#{code} · #{name}" : name
  end

  # Requirements that apply to someone holding role (CrewRole, id or nil): those for
  # everyone (crew_role_id nil) plus those for that role. Returns an Array; uses the
  # preloaded project_requirements association when loaded.
  def requirements_for(role)
    role_id = role.is_a?(CrewRole) ? role.id : role
    requirements = project_requirements.loaded? ? project_requirements : project_requirements.includes(:certificate_type)
    requirements.select { |requirement| requirement.applies_to?(role_id) }
  end

  # Adds other's requirements that this project lacks (skipping retired types). Returns the
  # number added. See Projects::CopyRequirements, which the requirements editor uses.
  def copy_requirements_from!(other)
    Projects::CopyRequirements.new(self, other).call.added
  end

  private
    def ends_on_not_before_starts_on
      return if starts_on.blank? || ends_on.blank? || ends_on >= starts_on

      errors.add(:ends_on, "can't be before the start date")
    end
end
