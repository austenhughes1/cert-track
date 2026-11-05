# Authenticity of a certificate, or of an import item before it becomes one (docs/PLAN.md, Phase 3b):
# whether its issuer confirmed it. Certificate and ImportItem share the authenticity_* columns.
#
#   unchecked      nothing tried yet
#   needs_check    a person should open the verification link or look the code up
#   verified       the issuer confirmed it and its details match (automatically, or a person did)
#   cannot_verify  the issuer has no public registry, or there is nothing to check with (counts as valid)
#   not_found      the issuer has no such certificate          } flagged
#   mismatch       the issuer's details differ from the card   }
#   suspicious     a QR code or link points to a lookalike site }
#
# Never omit a certificate unless it is verified fake (owner, Nov 4, 2026). A flagged result from an
# automatic check, a QR code's details or a lookalike link is only "flagged for review": the certificate
# keeps counting by its dates and stays in packets. Only a person's not_found or mismatch, recorded
# after checking with the issuer, makes it "confirmed fake": then it counts as not valid and is left
# out of packets (Compliance.status_for).
#
# A person's not_found or mismatch is about the details they checked: the issuer, verification code
# and link they looked up, and for a mismatch also the person and the card's dates they compared.
# The result keeps keyed digests of those details (record_authenticity!). When an edit makes them
# differ, it no longer shows that what is on record is fake, so it goes back to needs_check
# (method "details_changed", counting by its dates again) with a note saying what changed, and
# only a person or a definite automatic answer settles it (Verification::Run, rule 7). Each model
# says what its details are (authenticity_inputs) and which saves are edits (authenticity_edit?);
# Imports::Accept does the same for a certificate whose details differ, and
# Imports::ProcessExtractionJob for a new reading after Read again (reset_fake_for_new_reading!).
# A result recorded without the digests is compared with the details as stored before the edit.
module Authenticity
  extend ActiveSupport::Concern

  FLAGGED_STATUSES = %w[not_found mismatch suspicious].freeze
  FAKE_STATUSES = %w[not_found mismatch].freeze # confirmed fake when a person recorded them
  PERSON_STATUSES = %w[verified not_found mismatch cannot_verify].freeze # the result buttons
  PERSON_METHOD = "person".freeze
  DETAILS_CHANGED_METHOD = "details_changed".freeze
  # What a not_found was about (authenticity_inputs' keys); a mismatch is about all of them.
  LOOKUP_INPUTS = [ "issuer", "verification code", "verification link" ].freeze
  # Where a person's fake result keeps the digests of the details it was about (record_authenticity!).
  CHECKED_INPUTS_KEY = "checked_inputs".freeze
  # A reset's details (authenticity_reset_attributes) that a later definite result keeps (Verification::Run).
  RESET_HISTORY_KEYS = %w[previous_status previous_checked_by_id previous_checked_at previous_note changed].freeze

  # The verification list's filters and the dashboard's tiles, most severe first.
  REVIEW_FILTERS = %w[fake flagged needs_check].freeze

  LABELS = {
    "unchecked" => "Not checked yet",
    "needs_check" => "Needs a check",
    "verified" => "Verified",
    "cannot_verify" => "Can't be verified",
    "not_found" => "Not found by issuer",
    "mismatch" => "Doesn't match issuer",
    "suspicious" => "Suspicious link"
  }.freeze

  included do
    enum :authenticity_status,
      { unchecked: 0, needs_check: 1, verified: 2, cannot_verify: 3, not_found: 4, mismatch: 5, suspicious: 6 },
      prefix: :authenticity, default: :unchecked, validate: true

    belongs_to :authenticity_checked_by, class_name: "User", optional: true

    before_save :reset_fake_for_changed_details

    # Any flagged result, confirmed fake or not.
    scope :authenticity_flagged, -> { where(authenticity_status: FLAGGED_STATUSES) }
    scope :authenticity_confirmed_fake, -> { where(authenticity_status: FAKE_STATUSES, authenticity_method: PERSON_METHOD) }
    # Flagged, but not by a person: it still counts and stays in packets. (IS DISTINCT FROM keeps a
    # NULL method, which `where.not` would drop.)
    scope :authenticity_flagged_for_review, -> {
      authenticity_flagged.where(
        "#{quoted_table_name}.authenticity_status NOT IN (?) OR #{quoted_table_name}.authenticity_method IS DISTINCT FROM ?",
        authenticity_statuses.values_at(*FAKE_STATUSES), PERSON_METHOD)
    }
    scope :authenticity_needing_check, -> { where(authenticity_status: :needs_check) }
  end

  class_methods do
    # The records matching one of REVIEW_FILTERS ("fake", "flagged", "needs_check").
    def authenticity_review_filter(filter)
      case filter.to_s
      when "fake" then authenticity_confirmed_fake
      when "flagged" then authenticity_flagged_for_review
      when "needs_check" then authenticity_needing_check
      else raise ArgumentError, "unknown authenticity filter #{filter.inspect}"
      end
    end

    # { "fake" => n, "flagged" => n, "needs_check" => n } for this relation, in one grouped query.
    def authenticity_review_counts
      by_person = Arel.sql("#{quoted_table_name}.authenticity_method = #{connection.quote(PERSON_METHOD)}")
      rows = where(authenticity_status: FLAGGED_STATUSES + %w[needs_check]).group(:authenticity_status, by_person).count
      rows.each_with_object(REVIEW_FILTERS.index_with(0)) do |((status, person), count), counts|
        counts[review_filter_for(status, person == true)] += count
      end
    end

    # The REVIEW_FILTERS key for a status, given whether a person recorded it. status: a
    # FLAGGED_STATUSES one or needs_check (anything else would read "flagged").
    def review_filter_for(status, by_person)
      if status.to_s == "needs_check" then "needs_check"
      elsif by_person && FAKE_STATUSES.include?(status.to_s) then "fake"
      else "flagged"
      end
    end

    # An ORDER BY expression that puts confirmed fake rows first (fake_first: true) or last.
    def authenticity_confirmed_fake_order(fake_first:)
      Arel.sql(sanitize_sql_array([ "CASE WHEN #{quoted_table_name}.authenticity_status IN (?) AND " \
        "#{quoted_table_name}.authenticity_method = ? THEN ? ELSE ? END", authenticity_statuses.values_at(*FAKE_STATUSES),
        PERSON_METHOD, *(fake_first ? [ 0, 1 ] : [ 1, 0 ]) ]))
    end
  end

  # Any flagged result (not_found, mismatch, suspicious), confirmed fake or only flagged for review.
  def authenticity_flagged?
    FLAGGED_STATUSES.include?(authenticity_status)
  end

  # A person checked it with the issuer and recorded not_found or mismatch: it counts as not valid
  # and is left out of packets.
  def authenticity_confirmed_fake?
    FAKE_STATUSES.include?(authenticity_status) && authenticity_set_by_person?
  end

  # Flagged by an automatic check, a QR code's details or a lookalike link, and not (yet) confirmed
  # by a person: a red badge and the dashboard's list, but it still counts by its dates.
  def authenticity_flagged_for_review?
    authenticity_flagged? && !authenticity_confirmed_fake?
  end

  def authenticity_label
    LABELS.fetch(authenticity_status)
  end

  # A person's recorded result, which automatic checks leave alone until someone runs "Check again".
  def authenticity_set_by_person?
    authenticity_method == PERSON_METHOD
  end

  # Records a check. by: the user for a person's result (method "person"); nil for automatic ones.
  # status: one of the enum keys (a Verification::Result's :unavailable must be mapped first).
  # A person's not_found or mismatch also keeps what it was about: keyed digests of the record's
  # authenticity_inputs (details[CHECKED_INPUTS_KEY], never the codes or dates themselves).
  def record_authenticity!(status:, method:, note: nil, details: {}, by: nil, at: Time.current)
    details = details.to_h.deep_stringify_keys
    details = details.merge(CHECKED_INPUTS_KEY => authenticity_input_digests(authenticity_inputs)) if by && FAKE_STATUSES.include?(status.to_s)
    update!(authenticity_status: status.to_s, authenticity_method: by ? PERSON_METHOD : method.to_s,
      authenticity_note: note.presence, authenticity_details: details,
      authenticity_checked_by: by, authenticity_checked_at: at)
  end

  # inputs (authenticity_inputs) with each value a keyed digest, nil when blank: what a person's
  # fake result stores about the details it was about, and what is compared with them.
  def authenticity_input_digests(inputs)
    inputs.transform_values { |value| Authenticity.input_digest(value) if value.present? }
  end

  # The names of the details (authenticity_inputs_changed) whose values in now (authenticity_inputs)
  # differ from the ones this person's fake result was about: the digests stored with it, else
  # fallback (inputs as stored, for a result recorded without them), else none.
  def authenticity_changed_since_check(fallback = nil, now: authenticity_inputs)
    checked = authenticity_details.to_h[CHECKED_INPUTS_KEY]
    from = checked.is_a?(Hash) ? checked : (authenticity_input_digests(fallback) if fallback)
    from ? authenticity_inputs_changed(from, authenticity_input_digests(now)) : []
  end

  # After a new reading of the record's details (Imports::ProcessExtractionJob, once Imports::Reread
  # kept a person's fake result): the reset an edit makes, saved. Compared with the digests stored
  # with the result only: Read again cleared the details stored before the reading.
  def reset_fake_for_new_reading!
    return unless authenticity_confirmed_fake?

    changed = authenticity_changed_since_check
    update!(authenticity_reset_attributes(changed)) if changed.any?
  end

  # A keyed digest (HMAC-SHA256, 128 bits in hex) of one detail, so equal details compare equal
  # without being stored. A new secret_key_base makes every stored one differ: those fake results
  # then go back to needs a check at their next edit (counting again, never omitted by mistake).
  def self.input_digest(value)
    @input_digest_key ||= Rails.application.key_generator.generate_key("authenticity checked inputs", 32)
    OpenSSL::HMAC.hexdigest("SHA256", @input_digest_key, value.to_s).first(32)
  end

  # The authenticity_* attributes, for copying an import item's check onto its certificate.
  def authenticity_attributes
    attributes.slice(*%w[authenticity_status authenticity_checked_at authenticity_checked_by_id authenticity_method
      authenticity_note authenticity_details])
  end

  # The names ("verification code") of the details this record's not_found or mismatch was about
  # that differ between from and to (authenticity_inputs hashes, or both their digests). A compared
  # detail that was blank wasn't compared, so filling it in changes nothing.
  def authenticity_inputs_changed(from, to)
    from.keys.select do |name|
      next false if from[name] == to[name]

      LOOKUP_INPUTS.include?(name) || (authenticity_mismatch? && from[name].present?)
    end
  end

  # The attributes that turn this confirmed fake result back into needs_check, saying which details
  # (names from authenticity_inputs_changed) changed after a person recorded it. What the person
  # recorded is kept in the details (RESET_HISTORY_KEYS), their note included.
  def authenticity_reset_attributes(changed, at: Time.current)
    { "authenticity_status" => "needs_check", "authenticity_method" => DETAILS_CHANGED_METHOD,
      "authenticity_note" => "A person recorded “#{authenticity_label}”, but the #{changed.to_sentence} changed afterwards, " \
        "so it is no longer confirmed fake. Check it with the issuer again.",
      "authenticity_details" => { "previous_status" => authenticity_status, "previous_checked_by_id" => authenticity_checked_by_id,
        "previous_checked_at" => authenticity_checked_at&.iso8601, "previous_note" => authenticity_note.presence,
        "changed" => changed }.compact,
      "authenticity_checked_by_id" => nil, "authenticity_checked_at" => at }
  end

  # For the note of a result that replaced a reset: "Before this check, a person had recorded “Not
  # found by issuer”, but the verification code changed afterwards." nil without that history.
  def self.reset_history_sentence(details)
    status = details.to_h["previous_status"]
    changed = Array(details.to_h["changed"])
    return unless LABELS.key?(status) && changed.any?

    "Before this check, a person had recorded “#{LABELS.fetch(status)}”, but the #{changed.to_sentence} changed afterwards."
  end

  # Whether the last save turned a person's fake result back into needs_check.
  def authenticity_reset_by_last_save?
    saved_change_to_authenticity_method? && authenticity_method == DETAILS_CHANGED_METHOD
  end

  private
    # See the module comment. Not when the save records a check itself.
    def reset_fake_for_changed_details
      return unless authenticity_edit? && authenticity_confirmed_fake?
      return if will_save_change_to_authenticity_status? || will_save_change_to_authenticity_method?

      changed = authenticity_changed_since_check(authenticity_inputs(database: true))
      assign_attributes(authenticity_reset_attributes(changed)) if changed.any?
    end
end
