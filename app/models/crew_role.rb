class CrewRole < ApplicationRecord
  has_many :crew_members, dependent: :restrict_with_error
  has_many :project_requirements, dependent: :restrict_with_error
  has_many :project_assignments, dependent: :restrict_with_error

  normalizes :name, with: ->(name) { name.squish }

  validates :name, presence: true, uniqueness: true

  scope :ordered, -> { order(:name) }
end
