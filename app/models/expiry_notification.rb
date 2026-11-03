# Send log for expiry emails. The unique index on [certificate_id, threshold,
# recipient_email] makes each combination send once; insert before sending.
class ExpiryNotification < ApplicationRecord
  # Higher integer = more urgent.
  enum :threshold, { d90: 0, d60: 1, d30: 2, d7: 3, expired: 4 }, validate: true

  # Days-to-expiry at or below which a threshold is crossed (expired: below 0).
  THRESHOLD_DAYS = { "d90" => 90, "d60" => 60, "d30" => 30, "d7" => 7 }.freeze

  belongs_to :certificate

  normalizes :recipient_email, with: ->(email) { email.strip.downcase }

  validates :recipient_email, presence: true,
    uniqueness: { scope: %i[certificate_id threshold], case_sensitive: false }

  scope :sent, -> { where.not(sent_at: nil) }
  scope :unsent, -> { where(sent_at: nil) }

  # Most urgent threshold crossed with days_left until expiry (expires_on - today), or nil
  # when more than 90 days remain. 0 days left (expires today) is d7; negative is expired.
  def self.threshold_for(days_left)
    return if days_left.nil?
    return "expired" if days_left.negative?

    THRESHOLD_DAYS.select { |_, days| days_left <= days }.min_by { |_, days| days }&.first
  end
end
