class User < ApplicationRecord
  INVITATION_EXPIRES_IN = 7.days

  has_secure_password
  has_many :sessions, dependent: :destroy

  enum :role, { admin: 0, manager: 1, viewer: 2 }, default: :viewer, validate: true

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :name, with: ->(n) { n.squish.presence }

  validates :email_address, presence: true, uniqueness: true,
    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, allow_nil: true
  validate :keeps_an_admin, on: :update

  before_destroy :ensure_not_last_admin

  # Reset and invite links are keyed on the password salt, so they stop working once a
  # password is set, and on the email address, so a link sent to a mistyped address dies
  # when an admin corrects it. Redefines has_secure_password's reset token to add the
  # address. Invite links outlive the 15-minute reset token.
  generates_token_for :password_reset, expires_in: ActiveModel::SecurePassword::DEFAULT_RESET_TOKEN_EXPIRES_IN do
    token_fingerprint
  end

  generates_token_for :invitation, expires_in: INVITATION_EXPIRES_IN do
    token_fingerprint
  end

  scope :digest_recipients, -> { where(receives_digest: true, role: %i[admin manager]) }
  scope :ordered, -> { order(Arel.sql("lower(coalesce(users.name, users.email_address))")) }

  # Adds last_signed_in_at (latest session start) without a query per row.
  # Signing out deletes the session row, so this is the latest *open* session.
  scope :with_last_sign_in, -> {
    left_joins(:sessions).group(:id).select("users.*", "MAX(sessions.created_at) AS last_signed_in_at")
  }

  # Placeholder for invited accounts until the invitee picks their own password.
  def self.generate_password
    SecureRandom.base58(24)
  end

  # Backs bin/rails certtrack:create_admin. Creates the user or promotes an
  # existing one; the password changes only when one is given.
  def self.create_or_promote_admin!(email_address:, name: nil, password: nil)
    find_or_initialize_by(email_address: email_address).tap do |user|
      user.role = :admin
      user.name = name if name.present?
      user.password = password if password.present?
      user.save!
    end
  end

  def self.find_by_invitation_token(token)
    find_by_token_for(:invitation, token)
  end

  def invitation_token
    generate_token_for(:invitation)
  end

  # Admins and managers edit tracker data; viewers are read-only.
  def editor?
    admin? || manager?
  end

  def display_name
    name.presence || email_address
  end

  def last_signed_in_at
    value = has_attribute?(:last_signed_in_at) ? self[:last_signed_in_at] : sessions.maximum(:created_at)
    value&.in_time_zone
  end

  def last_admin?
    admin? && !User.admin.where.not(id: id).exists?
  end

  private
    # Token payloads are signed, not encrypted, so the address goes in as a digest.
    def token_fingerprint
      [ password_salt&.last(10), Digest::SHA256.hexdigest(email_address.to_s).first(16) ]
    end

    def keeps_an_admin
      if role_changed?(from: "admin") && other_admin_ids_locked.empty?
        errors.add(:role, "can't be changed: this is the only admin")
      end
    end

    def ensure_not_last_admin
      if admin? && other_admin_ids_locked.empty?
        errors.add(:base, "The only admin can't be deleted")
        throw :abort
      end
    end

    # Locks every admin row (in id order) before counting, so two overlapping demotions
    # or deletions queue up instead of each seeing the other as the remaining admin.
    # Validations and destroy callbacks run inside the save transaction, which holds the
    # lock until commit.
    def other_admin_ids_locked
      User.admin.order(:id).lock.ids - [ id ]
    end
end
