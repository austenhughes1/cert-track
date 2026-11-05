# One detected certificate from an import: a whole file, or a page range of a PDF.
# AI proposals stay here until a person (or the auto-accept rules) turns them into a Certificate.
class ImportItem < ApplicationRecord
  include Authenticity
  include ImageQualityFlags

  TERMINAL_STATUSES = %w[accepted rejected duplicate failed].freeze
  # Still being read by the pipeline (text extraction, then AI): the batch isn't finished.
  PIPELINE_STATUSES = %w[pending extracting].freeze
  PURGE_AFTER = 30.days

  enum :status, { pending: 0, extracting: 1, needs_review: 2, accepted: 3, rejected: 4, duplicate: 5, failed: 6 },
    default: :pending, validate: true

  # matched_crew_member / matched_certificate_type hold the exact match or the top suggestion;
  # these say which. Suggestions are [{ "id" =>, "name" =>, "similarity" => }] best first.
  # picked: a reviewer chose the person by hand and saved it ("Save edits"); shown as
  # "Picked by hand", and Imports::Accept learns no alias from it. A type picked by hand is
  # stored as type_match matched.
  enum :person_match, { unmatched: 0, suggested: 1, matched: 2, picked: 3 }, prefix: :person, default: :unmatched
  enum :type_match, { unmatched: 0, suggested: 1, matched: 2 }, prefix: :type, default: :unmatched
  # Phase 3b: matched by a QR/link domain or the model's issuer code; suggested by a fuzzy name.
  enum :issuer_match, { unmatched: 0, suggested: 1, matched: 2 }, prefix: :issuer, default: :unmatched
  # manual: a reviewer typed the expiry and saved it ("Save edits").
  enum :proposed_expires_on_source, { printed: 0, computed: 1, none: 2, manual: 3, printed_period: 4, no_expiration: 5 }, prefix: :proposed_expiry

  belongs_to :import_batch
  belongs_to :source_item, class_name: "ImportItem", optional: true, inverse_of: :split_items # the file this page range came from
  has_many :split_items, class_name: "ImportItem", foreign_key: :source_item_id, inverse_of: :source_item, dependent: :destroy
  belongs_to :matched_crew_member, class_name: "CrewMember", optional: true
  belongs_to :matched_certificate_type, class_name: "CertificateType", optional: true
  belongs_to :matched_certificate_issuer, class_name: "CertificateIssuer", optional: true
  belongs_to :certificate, optional: true # set on accept
  belongs_to :reviewed_by, class_name: "User", optional: true
  belongs_to :duplicate_of, class_name: "ImportItem", optional: true, inverse_of: :duplicates

  has_many :duplicates, class_name: "ImportItem", foreign_key: :duplicate_of_id, inverse_of: :duplicate_of, dependent: :nullify
  has_many :created_certificates, class_name: "Certificate", inverse_of: :import_item, dependent: :nullify # certificates.import_item_id
  has_one_attached :file

  encrypts :proposed_certificate_number, deterministic: true
  # Phase 3b. barcodes: QR codes decoded locally, [{ "page" => 1, "text" => "https://..." }]
  # (a QR link can carry the holder's name and certificate id); nil until the file is read.
  # No type: Array: with it a NULL column reads as [] and looks changed, so lock! refuses the record.
  serialize :barcodes, coder: JSON # declared before encrypts, as Rails requires
  encrypts :proposed_verification_code, :proposed_verification_url, :barcodes

  normalizes :page_range, :proposed_certificate_number, :holder_name_raw, :certificate_name_raw,
    :proposed_verification_code, with: ->(value) { value.squish.presence }
  normalizes :proposed_verification_url, with: ->(value) { Certificate.normalize_verification_url(value) }
  normalizes :sha256, with: ->(digest) { digest.strip.downcase }

  # A file rejected before it could be read (zip-slip, over a limit) has no digest.
  validates :sha256, format: { with: /\A\h{64}\z/, message: "must be a SHA-256 hex digest" },
    unless: -> { rejected? && sha256.nil? }
  validates :page_range, format: { with: /\A\d+(-\d+)?\z/ }, allow_nil: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :ai_units_used, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  scope :terminal, -> { where(status: TERMINAL_STATUSES) }
  scope :unfinished, -> { where.not(status: TERMINAL_STATUSES) }
  scope :in_pipeline, -> { where(status: PIPELINE_STATUSES) }
  # Oldest first; a skipped item goes behind every unskipped one (earliest skip first).
  scope :review_queue, -> { needs_review.order(arel_table[:skipped_at].asc.nulls_first, :id) }
  # Parked until the AI allocation resets (next_attempt_at still ahead).
  scope :waiting_for_budget, ->(now = Time.current) { in_pipeline.where(arel_table[:next_attempt_at].gt(now)) }
  # Finished items (accepted, rejected, duplicate or failed) whose raw reads (extracted_text,
  # extraction and the decoded QR codes in barcodes, which can hold the holder's name and
  # certificate id) are past the 30-day retention, counted from the review or, without one, the
  # last change. Failed items and split-off duplicates hold them too. needs_review items are kept.
  scope :purgeable, ->(now: Time.current) {
    terminal
      .where("coalesce(import_items.reviewed_at, import_items.updated_at) < ?", now - PURGE_AFTER)
      .where("import_items.extracted_text IS NOT NULL OR import_items.extraction IS NOT NULL OR import_items.barcodes IS NOT NULL")
  }
  # Failed items past the same 30 days, whose files are deleted (purge_stale_files!). Rejected
  # items keep theirs: a rejected file stays the original that a later upload of it
  # duplicates, so a wrong rejection can only be undone with Read again. An accepted item's
  # file is its certificate's (Imports::Accept), and a duplicate has none.
  scope :file_purgeable, ->(now: Time.current) {
    failed.where("coalesce(import_items.reviewed_at, import_items.updated_at) < ?", now - PURGE_AFTER)
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

    # The earlier item for the same file (any page range) that a new upload of it would
    # duplicate, or nil: the whole-file item when there is one. Same exclusions as original_for.
    def original_file_for(sha256)
      where(sha256: sha256.to_s.strip.downcase)
        .where.not(status: %i[duplicate failed])
        .order(arel_table[:source_item_id].asc.nulls_first, :id)
        .first
    end

    # original_file_for for many files in one query: { sha256 => item } for each digest that
    # has an original.
    def original_files_for(sha256s)
      digests = Array(sha256s).map { |digest| digest.to_s.strip.downcase }.uniq
      return {} if digests.empty?

      where(sha256: digests)
        .where.not(status: %i[duplicate failed])
        .select("DISTINCT ON (import_items.sha256) import_items.*")
        .order(:sha256, arel_table[:source_item_id].asc.nulls_first, :id)
        .index_by(&:sha256)
    end

    # Clears extracted_text, extraction and barcodes on purgeable items (Imports::ExtractTextJob
    # reads the QR codes again if the item is read again). Returns the number cleared.
    def purge_stale_extractions!(now: Time.current)
      purgeable(now: now).update_all(extracted_text: nil, extraction: nil, barcodes: nil, updated_at: now)
    end

    # Deletes the files of file_purgeable items (Imports::FileCleanup: a blob a certificate
    # still holds stays). The items aren't touched; run it before purge_stale_extractions!,
    # which does count as a change. The file can't come back: upload it again to read it
    # (a failed item is never the original, so that makes a new item). Returns the number of
    # files deleted.
    def purge_stale_files!(now: Time.current)
      Imports::FileCleanup.delete(
        ActiveStorage::Attachment.where(record_type: polymorphic_name, name: "file", record_id: file_purgeable(now:).select(:id))
      )
    end
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def in_pipeline?
    PIPELINE_STATUSES.include?(status)
  end

  def waiting_for_budget?(now = Time.current)
    in_pipeline? && next_attempt_at.present? && next_attempt_at > now
  end

  # "ortiz.jpg" for "crew.zip/cards/ortiz.jpg".
  def filename
    File.basename(original_filename.to_s).presence
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

  # The expiry printed on this item's card that the AI could not read as a date ("06/2027"),
  # or nil. Imports::Extraction::Normalizer keeps it under "unreadable". The item's own
  # certificate is the first in extraction: Imports::Splitter leaves the first on the file's
  # item and gives each split-off item only its own.
  def unreadable_expires_on
    data = extraction.is_a?(Hash) ? extraction.deep_stringify_keys : {}
    certificate = Array(data["certificates"]).find { |entry| entry.is_a?(Hash) }
    unreadable = certificate&.dig("unreadable")
    unreadable["expires_on"].to_s.squish.presence if unreadable.is_a?(Hash)
  end

  # What a check of this item is about (Authenticity), as it will be saved or (database: true) as
  # stored: the issuer, code and link looked up, and the person and card dates compared. An expiry
  # worked out from the type isn't the card's.
  def authenticity_inputs(database: false)
    value = database ? method(:attribute_in_database) : method(:read_attribute)
    derived = %w[computed none printed_period].include?(value.call("proposed_expires_on_source"))
    { "issuer" => value.call("matched_certificate_issuer_id"), "verification code" => value.call("proposed_verification_code"),
      "verification link" => value.call("proposed_verification_url"), "person" => value.call("matched_crew_member_id"),
      "completion date" => value.call("proposed_completed_on"), "expiry date" => (value.call("proposed_expires_on") unless derived) }
  end

  private
    # Only a reviewer's edits reset a person's fake result (Authenticity): not the pipeline's
    # reading (Imports::Reread keeps a confirmed fake through it), nor accepting or rejecting.
    def authenticity_edit?
      persisted? && needs_review? && !will_save_change_to_status?
    end
end
