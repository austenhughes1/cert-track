# One detected certificate from an import: a whole file, or a page range of a PDF.
# AI proposals stay here until a person (or the auto-accept rules) turns them into a Certificate.
class ImportItem < ApplicationRecord
  TERMINAL_STATUSES = %w[accepted rejected duplicate failed].freeze
  PURGE_AFTER = 30.days

  enum :status, { pending: 0, extracting: 1, needs_review: 2, accepted: 3, rejected: 4, duplicate: 5, failed: 6 },
    default: :pending, validate: true

  # matched_crew_member / matched_certificate_type hold the exact match or the top suggestion;
  # these say which. Suggestions are [{ "id" =>, "name" =>, "similarity" => }] best first.
  enum :person_match, { unmatched: 0, suggested: 1, matched: 2 }, prefix: :person, default: :unmatched
  enum :type_match, { unmatched: 0, suggested: 1, matched: 2 }, prefix: :type, default: :unmatched
  enum :proposed_expires_on_source, { printed: 0, computed: 1, none: 2 }, prefix: :proposed_expiry

  belongs_to :import_batch
  belongs_to :source_item, class_name: "ImportItem", optional: true, inverse_of: :split_items # the file this page range came from
  has_many :split_items, class_name: "ImportItem", foreign_key: :source_item_id, inverse_of: :source_item, dependent: :destroy
  belongs_to :matched_crew_member, class_name: "CrewMember", optional: true
  belongs_to :matched_certificate_type, class_name: "CertificateType", optional: true
  belongs_to :certificate, optional: true # set on accept
  belongs_to :reviewed_by, class_name: "User", optional: true
  belongs_to :duplicate_of, class_name: "ImportItem", optional: true, inverse_of: :duplicates

  has_many :duplicates, class_name: "ImportItem", foreign_key: :duplicate_of_id, inverse_of: :duplicate_of, dependent: :nullify
  has_many :created_certificates, class_name: "Certificate", inverse_of: :import_item, dependent: :nullify # certificates.import_item_id
  has_one_attached :file

  encrypts :proposed_certificate_number, deterministic: true

  normalizes :page_range, :proposed_certificate_number, :holder_name_raw, :certificate_name_raw,
    with: ->(value) { value.squish.presence }
  normalizes :sha256, with: ->(digest) { digest.strip.downcase }

  validates :sha256, format: { with: /\A\h{64}\z/, message: "must be a SHA-256 hex digest" }
  validates :page_range, format: { with: /\A\d+(-\d+)?\z/ }, allow_nil: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :ai_units_used, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  scope :terminal, -> { where(status: TERMINAL_STATUSES) }
  scope :unfinished, -> { where.not(status: TERMINAL_STATUSES) }
  scope :review_queue, -> { needs_review.order(:id) }
  # Accepted or rejected items whose extracted_text/extraction are past the 30-day retention.
  scope :purgeable, ->(now: Time.current) {
    where(status: %i[accepted rejected])
      .where("coalesce(import_items.reviewed_at, import_items.updated_at) < ?", now - PURGE_AFTER)
      .where("import_items.extracted_text IS NOT NULL OR import_items.extraction IS NOT NULL")
  }

  class << self
    # The earlier item for the same file and page range that a new item would duplicate,
    # or nil. Ignores other duplicates and failed items (a failed file may be retried).
    def original_for(sha256, page_range)
      where(sha256: sha256.to_s.strip.downcase, page_range: page_range.presence)
        .where.not(status: %i[duplicate failed])
        .order(:id)
        .first
    end

    # Clears extracted_text and extraction on purgeable items. Returns the number cleared.
    def purge_stale_extractions!(now: Time.current)
      purgeable(now: now).update_all(extracted_text: nil, extraction: nil, updated_at: now)
    end
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  # [1, 2] for "1-2", [3] for "3", [] when nil.
  def pages
    return [] if page_range.blank?

    first, last = page_range.split("-").map(&:to_i)
    (first..(last || first)).to_a
  end

  def mark_duplicate_of!(original)
    update!(status: :duplicate, duplicate_of: original)
  end
end
