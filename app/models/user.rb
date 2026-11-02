class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  enum :role, { admin: 0, manager: 1, viewer: 2 }, default: :viewer, validate: true

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, uniqueness: true,
    format: { with: URI::MailTo::EMAIL_REGEXP }

  scope :digest_recipients, -> { where(receives_digest: true, role: %i[admin manager]) }

  # Admins and managers edit tracker data; viewers are read-only.
  def editor?
    admin? || manager?
  end

  def display_name
    name.presence || email_address
  end
end
