# One earned certificate (a line item) for a crew member. For each member and type,
# the current certificate is the one with superseded_at nil: the latest completed_on,
# ties going to the highest id. Older ones are kept as history. A certificate a person
# confirmed fake (Authenticity) ranks below every other one, so a genuine card on file stays
# current, and counts, when a newer one turns out fake (owner, Nov 4, 2026: never omit a
# certificate unless it is verified fake); recording or replacing that result re-ranks them.
class Certificate < ApplicationRecord
  include Authenticity

  ALLOWED_CONTENT_TYPES = %w[application/pdf image/jpeg image/png image/heic image/heif image/webp].freeze
  MAX_FILE_SIZE = 25.megabytes
  # Phone photos that browsers can't show; Certificates::ShrinkFilesJob always turns them into JPEGs.
  HEIC_CONTENT_TYPES = %w[image/heic image/heif].freeze

  # printed: taken from the card; computed: completed_on + type validity; manual: typed
  # by a user; none: the type never expires.
  enum :expires_on_source, { printed: 0, computed: 1, manual: 2, none: 3, printed_period: 4, no_expiration: 5 }, prefix: :expiry, default: :manual, validate: true
  enum :source, { manual: 0, import: 1 }, prefix: true, default: :manual, validate: true

  belongs_to :crew_member
  belongs_to :certificate_type
  belongs_to :import_item, optional: true, inverse_of: :created_certificates # the import item this was created from
  belongs_to :verified_by, class_name: "User", optional: true
  belongs_to :certificate_issuer, optional: true # who issued it; issued_by keeps the name as printed

  has_many :import_items, dependent: :nullify # items accepted into this certificate (front/back merge)
  has_many :expiry_notifications, dependent: :delete_all

  has_many_attached :files do |attachable|
    attachable.variant :thumb, resize_to_limit: [ 320, 320 ]
  end

  encrypts :certificate_number, deterministic: true
  # Phase 3b: the code to type into the issuer's lookup, and the direct verification link (a QR link
  # can carry the holder's name).
  encrypts :verification_code, :verification_url

  normalizes :certificate_number, :issued_by, :verification_code, with: ->(value) { value.squish.presence }
  normalizes :verification_url, with: ->(value) { Certificate.normalize_verification_url(value) }

  before_validation :apply_expiration_rule

  validates :completed_on, presence: true
  validate :completed_on_not_in_future
  validate :expires_on_not_before_completed_on
  validate :files_are_allowed

  before_save :assign_current_flag
  after_save :reconcile_affected_groups
  after_update :rearm_expiry_notifications, if: :expiry_alert_inputs_changed?
  # The crew member before the row, as saves and Verification::Run lock them, so the two never deadlock.
  before_destroy :lock_crew_members, prepend: true
  after_destroy :reconcile_after_destroy
  after_save :note_new_files
  # In this order (after_commit callbacks run as declared): QR codes are read from the files as
  # uploaded, before the shrink job may replace them, and shrink_new_files_later clears the ids.
  after_commit :read_qr_codes_later, on: %i[create update]
  after_commit :shrink_new_files_later, on: %i[create update]

  scope :current, -> { where(superseded_at: nil) }
  scope :superseded, -> { where.not(superseded_at: nil) }
  # Date filters only; chain .current for live certificates.
  scope :expiring_within, ->(days, today: Date.current) { where(expires_on: today..(today + days)) }
  scope :expired, ->(today: Date.current) { where(expires_on: ...today) }
  scope :never_expiring, -> { where(expires_on: nil) }
  scope :chronological, -> { order(completed_on: :desc, id: :desc) }

  # A verification link as stored: stripped, with https:// added to a bare "redcross.org/confirm";
  # nil when blank or not a web address. (Also used for ImportItem#proposed_verification_url.)
  def self.normalize_verification_url(value)
    text = value.to_s.strip
    return if text.blank?

    text = "https://#{text}" unless text.match?(%r{\Ahttps?://}i)
    text = text.sub(%r{\Ahttp://}i, "https://")
    text if CertificateIssuer.host_of(text)
  end

  # Re-derives which certificate is current for one member and type: the latest
  # completed_on (ties -> highest id) that isn't confirmed fake becomes current (the latest
  # fake one when they all are), every other one superseded.
  # Writes supersessions before the promotion so the partial unique index holds.
  def self.reconcile_current!(crew_member_id, certificate_type_id)
    transaction do
      CrewMember.where(id: crew_member_id).lock.pluck(:id)
      group = where(crew_member_id: crew_member_id, certificate_type_id: certificate_type_id)
      winner_id = group.order(*currency_order).pick(:id)

      if winner_id
        now = Time.current
        group.where(superseded_at: nil).where.not(id: winner_id).update_all(superseded_at: now, updated_at: now)
        group.where(id: winner_id).where.not(superseded_at: nil).update_all(superseded_at: nil, updated_at: now)
      end
    end
  end

  # Best first: not confirmed fake, then the latest completed_on, then the highest id.
  def self.currency_order
    [ authenticity_confirmed_fake_order(fake_first: false), { completed_on: :desc, id: :desc } ]
  end

  def current?
    superseded_at.nil?
  end

  def superseded?
    !current?
  end

  def never_expires?
    expires_on.nil?
  end

  # The "No expiration" tick box: the certificate itself says it has none (source no_expiration), as
  # opposed to a type that never expires (none). It stays whatever the type's validity becomes.
  def no_expiration
    expiry_no_expiration?
  end

  def no_expiration=(value)
    if ActiveModel::Type::Boolean.new.cast(value)
      self.expires_on = nil
      self.expires_on_source = :no_expiration
    elsif expiry_no_expiration?
      self.expires_on_source = :manual # blank then works it out from the type again
    end
  end

  # Days from today to expires_on (negative once expired); nil when it never expires.
  def days_until_expiry(today: Date.current)
    (expires_on - today).to_i if expires_on
  end

  # See Compliance.status_for.
  def compliance_status(today: Date.current, project_ends_on: nil)
    Compliance.status_for(self, today: today, project_ends_on: project_ends_on)
  end

  # What a check of this certificate is about (Authenticity), as it will be saved or (database:
  # true) as stored: the issuer, code and link looked up, and the person and card dates compared.
  # An expiry worked out from the type isn't the card's. Same keys as ImportItem's.
  def authenticity_inputs(database: false)
    value = database ? method(:attribute_in_database) : method(:read_attribute)
    derived = %w[computed none printed_period].include?(value.call("expires_on_source"))
    { "issuer" => value.call("certificate_issuer_id"), "verification code" => value.call("verification_code"),
      "verification link" => value.call("verification_url"), "person" => value.call("crew_member_id"),
      "completion date" => value.call("completed_on"), "expiry date" => (value.call("expires_on") unless derived) }
  end

  # Called by CertificateType when its validity_months changes. Computed and never-expiring
  # dates were derived from the old validity, so they become completed_on + the new one
  # (or nil when the type no longer expires). Printed and manual dates are kept. Returns
  # true when the date was rewritten. Only these two derived columns change, so validations
  # are skipped: a problem elsewhere on an old row must not block the certificate type edit.
  # Callbacks still run, so the send log is re-armed for the new date.
  def rederive_expiry!
    return false unless expiry_computed? || expiry_none?

    assign_derived_expiry
    return false unless changed?

    save!(validate: false)
  end

  private
    # Any edit of a saved certificate can reset a person's fake result (Authenticity).
    def authenticity_edit?
      persisted?
    end

    # Explicit date: kept (source stays as the caller set it, e.g. printed or printed_period; else manual).
    # Blank date: completed_on + validity (computed), or nil when the type never expires (none).
    # On edit, a computed date follows changes to completed_on or type; other dates are
    # only recalculated when cleared. A change to the type's validity re-derives computed
    # and none rows through rederive_expiry!.
    def apply_expiration_rule
      return if expiry_no_expiration? && expires_on.blank?

      inputs_changed = new_record? || will_save_change_to_completed_on? || will_save_change_to_certificate_type_id?

      if expires_on.present?
        if expiry_computed? && !will_save_change_to_expires_on? && inputs_changed && !new_record?
          assign_derived_expiry
        elsif will_save_change_to_expires_on? && !will_save_change_to_expires_on_source?
          self.expires_on_source = :manual
        end
      elsif inputs_changed || will_save_change_to_expires_on? || will_save_change_to_expires_on_source?
        assign_derived_expiry
      end
    end

    def assign_derived_expiry
      self.expires_on = certificate_type&.expiry_for(completed_on)
      self.expires_on_source = expires_on ? :computed : :none
    end

    def completed_on_not_in_future
      errors.add(:completed_on, "can't be in the future") if completed_on && completed_on > Date.current
    end

    def expires_on_not_before_completed_on
      return if completed_on.blank? || expires_on.blank? || expires_on >= completed_on

      errors.add(:expires_on, "can't be before the completion date")
    end

    def files_are_allowed
      files.each do |file|
        next unless file.blob

        unless ALLOWED_CONTENT_TYPES.include?(file.blob.content_type)
          errors.add(:files, "#{file.blob.filename} must be a PDF, JPG, PNG, HEIC or WEBP")
        end
        errors.add(:files, "#{file.blob.filename} is larger than 25 MB") if file.blob.byte_size > MAX_FILE_SIZE
      end
    end

    def currency_inputs_changing?
      new_record? || will_save_change_to_completed_on? ||
        will_save_change_to_crew_member_id? || will_save_change_to_certificate_type_id? || confirmed_fake_changing?
    end

    # A person's Not found or Doesn't match recorded, or replaced (Check again, another result).
    def confirmed_fake_changing?
      return false unless will_save_change_to_authenticity_status? || will_save_change_to_authenticity_method?

      was_fake = FAKE_STATUSES.include?(authenticity_status_in_database) && authenticity_method_in_database == PERSON_METHOD
      was_fake != authenticity_confirmed_fake?
    end

    # Decides this row's superseded_at before it is written. When it outranks the rest of
    # its group, other current rows are superseded first so the insert/update never
    # collides with the one-current-per-member-and-type unique index.
    def assign_current_flag
      @currency_changed = currency_inputs_changing?
      return unless @currency_changed

      lock_crew_members
      rivals = Certificate.where(crew_member_id: crew_member_id, certificate_type_id: certificate_type_id)
      rivals = rivals.where.not(id: id) if persisted?
      newest_rival = rivals.order(*Certificate.currency_order).first

      if newest_rival.nil? || outranks?(newest_rival)
        now = Time.current
        rivals.where(superseded_at: nil).update_all(superseded_at: now, updated_at: now)
        self.superseded_at = nil
      else
        self.superseded_at ||= Time.current
      end
    end

    # Whether this one should be current rather than other (currency_order).
    def outranks?(other)
      return other.authenticity_confirmed_fake? if authenticity_confirmed_fake? != other.authenticity_confirmed_fake?
      return completed_on > other.completed_on if completed_on != other.completed_on

      new_record? || id > other.id
    end

    # Locks the member rows (old and new, in id order) so concurrent writes for one
    # person are serialized.
    def lock_crew_members
      ids = [ crew_member_id, (crew_member_id_in_database if persisted?) ].compact.uniq.sort
      CrewMember.where(id: ids).order(:id).lock.pluck(:id)
    end

    # assign_current_flag ranked this row by what this object holds, which may be older than the rows
    # it ranked against (a job's copy, loaded seconds ago): the group is re-derived from the database
    # under the same lock, and this row's flag read back into the object.
    def reconcile_affected_groups
      return unless @currency_changed

      @currency_changed = false
      self.class.reconcile_current!(crew_member_id, certificate_type_id)
      read_back_current_flag
      # Moved to another member or type: re-promote in the group it left.
      if !previously_new_record? && (saved_change_to_crew_member_id? || saved_change_to_certificate_type_id?)
        self.class.reconcile_current!(crew_member_id_before_last_save, certificate_type_id_before_last_save)
      end
    end

    # Only when it disagrees on current or not: the decision's own timestamp stays as it was set.
    def read_back_current_flag
      stored = self.class.where(id: id).pick(:superseded_at)
      return if stored.nil? == superseded_at.nil?

      self.superseded_at = stored
      clear_attribute_changes(%w[superseded_at])
    end

    def reconcile_after_destroy
      self.class.reconcile_current!(crew_member_id, certificate_type_id) if current?
    end

    def expiry_alert_inputs_changed?
      saved_change_to_expires_on? || saved_change_to_certificate_type_id? || saved_change_to_crew_member_id?
    end

    # A corrected or extended expiry date re-arms the alerts it hasn't reached yet: send-log
    # rows for thresholds more urgent than the one the new date has crossed are removed, so
    # the scan can send them again. Rows at or below that threshold stay, so nothing repeats.
    # A corrected type or person clears the whole log: every alert so far named the wrong
    # certificate, so the scan sends the current threshold again, once.
    def rearm_expiry_notifications
      if saved_change_to_certificate_type_id? || saved_change_to_crew_member_id?
        expiry_notifications.delete_all
        return
      end

      crossed = ExpiryNotification.threshold_for(days_until_expiry)
      urgency = crossed ? ExpiryNotification.thresholds.fetch(crossed) : -1
      expiry_notifications.where("expiry_notifications.threshold > ?", urgency).delete_all
    end

    # Only saves that attach files queue the shrink and QR jobs, and only for the attachments
    # they created (attach passes the files already there too). Active Storage also touches the
    # record when it analyzes each blob, and the shrink job swaps files itself: neither queues
    # them again.
    def note_new_files
      change = attachment_changes["files"]
      return unless change.respond_to?(:attachments)

      (@new_file_attachment_ids ||= []).concat(change.attachments.select(&:previously_new_record?).map(&:id))
    end

    # Phase 3b. Not for a certificate an import just created: the pipeline read its QR codes
    # already, and Imports::Accept copies its verification link and check.
    def read_qr_codes_later
      ids = @new_file_attachment_ids&.uniq
      return if ids.blank? || (source_import? && previously_new_record?)

      Certificates::ReadQrCodesJob.perform_later(self, ids)
    end

    def shrink_new_files_later
      ids = @new_file_attachment_ids&.uniq
      @new_file_attachment_ids = nil
      Certificates::ShrinkFilesJob.perform_later(self, ids) if ids.present?
    end
end
