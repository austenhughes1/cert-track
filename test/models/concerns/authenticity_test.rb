require "test_helper"

# Authenticity (app/models/concerns/authenticity.rb), on both models that include it. Never omit a
# certificate unless it is verified fake (owner, Nov 4, 2026): only a person's not_found or mismatch
# is confirmed fake; every other flagged result is only flagged for review.
class AuthenticityTest < ActiveSupport::TestCase
  MODELS = [ Certificate, ImportItem ].freeze

  # [status, method] => [flagged?, confirmed_fake?, flagged_for_review?]
  CASES = {
    [ "not_found", "person" ] => [ true, true, false ],
    [ "mismatch", "person" ] => [ true, true, false ],
    [ "suspicious", "person" ] => [ true, false, true ], # the panel can't record it (PERSON_STATUSES); a stray row isn't fake
    [ "not_found", "automatic:national_cpr_foundation" ] => [ true, false, true ],
    [ "mismatch", "automatic:national_osha_foundation" ] => [ true, false, true ],
    [ "mismatch", "qr_details:qr_details_360training" ] => [ true, false, true ],
    [ "suspicious", "qr_link" ] => [ true, false, true ],
    [ "suspicious", "verification_link" ] => [ true, false, true ],
    [ "not_found", nil ] => [ true, false, true ],
    [ "mismatch", nil ] => [ true, false, true ],
    [ "verified", "person" ] => [ false, false, false ],
    [ "cannot_verify", "person" ] => [ false, false, false ],
    [ "verified", "automatic:aha_ecards" ] => [ false, false, false ],
    [ "needs_check", "automatic:osha_card_portal" ] => [ false, false, false ],
    [ "needs_check", nil ] => [ false, false, false ],
    [ "cannot_verify", "rules" ] => [ false, false, false ],
    [ "unchecked", nil ] => [ false, false, false ]
  }.freeze

  setup { @serial = 0 }

  # A saved record of model holding status and method as stored (update_columns, so a NULL method
  # or a person's "suspicious" can be set the way an old or stray row could hold it). Each
  # certificate is its own person's, so each is current.
  def stored(model, status, method)
    @serial += 1
    record = if model == Certificate
      member = CrewMember.create!(first_name: "Test", last_name: "Person #{@serial}")
      Certificate.create!(crew_member: member, certificate_type: certificate_types(:osha30), completed_on: Date.current - 10)
    else
      ImportItem.create!(import_batch: import_batches(:march_batch), sha256: Digest::SHA256.hexdigest("authenticity #{@serial}"))
    end
    record.update_columns(authenticity_status: model.authenticity_statuses.fetch(status), authenticity_method: method)
    record
  end

  # One stored record per case: { [status, method] => record }.
  def stored_cases(model)
    CASES.keys.to_h { |(status, method)| [ [ status, method ], stored(model, status, method) ] }
  end

  # The records whose case says column (0 flagged?, 1 confirmed_fake?, 2 flagged_for_review?) is true.
  def expected(records, column)
    records.select { |key, _| CASES.fetch(key)[column] }.values.map(&:id).sort
  end

  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:cached] || payload[:name].in?(%w[SCHEMA TRANSACTION]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { ActiveRecord::Base.uncached(&block) }
    count
  end

  test "constants" do
    assert_equal %w[not_found mismatch suspicious], Authenticity::FLAGGED_STATUSES
    assert_equal %w[not_found mismatch], Authenticity::FAKE_STATUSES
    assert_equal %w[verified not_found mismatch cannot_verify], Authenticity::PERSON_STATUSES
    assert_not_includes Authenticity::PERSON_STATUSES, "suspicious", "a person never records a suspicious link"
    assert_equal "person", Authenticity::PERSON_METHOD
    assert_equal %w[fake flagged needs_check], Authenticity::REVIEW_FILTERS, "most severe first"
    MODELS.each do |model|
      assert_equal model.authenticity_statuses.keys.sort, Authenticity::LABELS.keys.sort, model.name
    end
  end

  test "the enum: unchecked by default, prefixed, and an unknown status is invalid" do
    MODELS.each do |model|
      record = model.new
      assert record.authenticity_unchecked?, model.name
      assert_equal %w[unchecked needs_check verified cannot_verify not_found mismatch suspicious], model.authenticity_statuses.keys
      record.authenticity_status = "forged"
      assert_not record.valid?
      assert_includes record.errors[:authenticity_status], "is not included in the list", model.name
    end
  end

  test "flagged, confirmed fake and flagged for review, by status and who recorded it" do
    MODELS.each do |model|
      CASES.each do |(status, method), (flagged, fake, for_review)|
        record = model.new(authenticity_status: status, authenticity_method: method)
        message = "#{model.name} #{status} by #{method.inspect}"

        assert_equal flagged, record.authenticity_flagged?, message
        assert_equal fake, record.authenticity_confirmed_fake?, message
        assert_equal for_review, record.authenticity_flagged_for_review?, message
        assert_equal method == "person", record.authenticity_set_by_person?, message
      end
    end
  end

  test "authenticity_label names each status" do
    MODELS.each do |model|
      Authenticity::LABELS.each do |status, label|
        assert_equal label, model.new(authenticity_status: status).authenticity_label
      end
      assert_equal "Not found by issuer", model.new(authenticity_status: :not_found).authenticity_label
      assert_equal "Not checked yet", model.new.authenticity_label
    end
  end

  test "scopes: flagged, confirmed fake, flagged for review (a NULL method included) and needing a check" do
    MODELS.each do |model|
      records = stored_cases(model)
      relation = model.where(id: records.values.map(&:id))

      assert_equal expected(records, 0), relation.authenticity_flagged.ids.sort, "#{model.name} flagged"
      assert_equal expected(records, 1), relation.authenticity_confirmed_fake.ids.sort, "#{model.name} confirmed fake"
      assert_equal expected(records, 2), relation.authenticity_flagged_for_review.ids.sort, "#{model.name} flagged for review"
      assert_includes relation.authenticity_flagged_for_review, records.fetch([ "not_found", nil ]), "a NULL method isn't a person's"
      assert_includes relation.authenticity_flagged_for_review, records.fetch([ "suspicious", "person" ])
      assert_equal records.values_at([ "needs_check", "automatic:osha_card_portal" ], [ "needs_check", nil ]).map(&:id).sort,
        relation.authenticity_needing_check.ids.sort, model.name

      # Fake and flagged for review split the flagged records between them.
      assert_equal relation.authenticity_flagged.ids.sort,
        (relation.authenticity_confirmed_fake.ids + relation.authenticity_flagged_for_review.ids).sort
    end
  end

  test "the flagged-for-review scope names its table, so it works across a join" do
    item = stored(ImportItem, "mismatch", "automatic:national_osha_foundation")
    item.update_columns(certificate_id: stored(Certificate, "not_found", "person").id)

    # Both tables have authenticity_status and authenticity_method.
    assert_equal [ item ], ImportItem.joins(:certificate).where(id: item).authenticity_flagged_for_review.to_a
    assert_empty ImportItem.joins(:certificate).where(id: item).authenticity_confirmed_fake
    assert_equal [ item.certificate ], Certificate.joins(:import_items).where(id: item.certificate_id).authenticity_confirmed_fake.to_a
  end

  test "authenticity_review_filter returns each filter's records and refuses an unknown one" do
    MODELS.each do |model|
      records = stored_cases(model)
      relation = model.where(id: records.values.map(&:id))

      assert_equal expected(records, 1), relation.authenticity_review_filter("fake").ids.sort
      assert_equal expected(records, 2), relation.authenticity_review_filter(:flagged).ids.sort
      assert_equal relation.authenticity_needing_check.ids.sort, relation.authenticity_review_filter("needs_check").ids.sort
      [ "", nil, "flagged_for_review", "suspicious", "missing" ].each do |filter|
        error = assert_raises(ArgumentError) { relation.authenticity_review_filter(filter) }
        assert_equal "unknown authenticity filter #{filter.inspect}", error.message
      end
    end
  end

  test "authenticity_review_counts counts each filter in one grouped query" do
    MODELS.each do |model|
      records = stored_cases(model)
      relation = model.where(id: records.values.map(&:id))
      counts = nil

      assert_equal 1, count_queries { counts = relation.authenticity_review_counts }, model.name
      assert_equal({ "fake" => 2, "flagged" => 8, "needs_check" => 2 }, counts, model.name)
      assert_equal Authenticity::REVIEW_FILTERS, counts.keys
      Authenticity::REVIEW_FILTERS.each do |filter|
        assert_equal relation.authenticity_review_filter(filter).count, counts.fetch(filter), "#{model.name} #{filter}"
      end
      assert_equal({ "fake" => 0, "flagged" => 0, "needs_check" => 0 }, model.none.authenticity_review_counts)
    end
  end

  test "authenticity_review_counts chains on any relation, joins included" do
    fake = stored(Certificate, "not_found", "person")
    flagged = stored(Certificate, "mismatch", "automatic:national_osha_foundation")
    fake.crew_member.update_columns(active: false)

    counts = Certificate.current.joins(:crew_member).merge(CrewMember.active).where(id: [ fake, flagged ])
      .authenticity_review_counts
    assert_equal({ "fake" => 0, "flagged" => 1, "needs_check" => 0 }, counts, "the inactive member's fake one is left out")

    item = stored(ImportItem, "suspicious", "qr_link")
    item.update_columns(certificate_id: fake.id)
    assert_equal({ "fake" => 0, "flagged" => 1, "needs_check" => 0 }, ImportItem.joins(:certificate).where(id: item).authenticity_review_counts)
  end

  test "review_filter_for gives the filter for a status and whether a person recorded it" do
    MODELS.each do |model|
      assert_equal "fake", model.review_filter_for("not_found", true)
      assert_equal "fake", model.review_filter_for(:mismatch, true)
      assert_equal "flagged", model.review_filter_for("suspicious", true)
      assert_equal "flagged", model.review_filter_for("not_found", false)
      assert_equal "flagged", model.review_filter_for(:mismatch, nil)
      assert_equal "flagged", model.review_filter_for("suspicious", false)
      assert_equal "needs_check", model.review_filter_for("needs_check", true)
      assert_equal "needs_check", model.review_filter_for(:needs_check, false)
    end
  end

  test "record_authenticity! by a person sets method person and the checker; a fake result is then confirmed" do
    manager = users(:manager)
    at = Time.zone.local(2026, 11, 4, 9, 30)

    MODELS.each do |model|
      record = stored(model, "not_found", "automatic:national_cpr_foundation")
      assert record.authenticity_flagged_for_review?

      record.record_authenticity!(status: :not_found, method: "anything", note: "Called the issuer: no such card",
        details: { issuer_status: "none" }, by: manager, at: at)
      record.reload

      assert_equal [ "not_found", "person", manager, at ],
        [ record.authenticity_status, record.authenticity_method, record.authenticity_checked_by, record.authenticity_checked_at ]
      assert_equal [ "Called the issuer: no such card", "none" ], [ record.authenticity_note, record.authenticity_details["issuer_status"] ]
      assert_equal [ "checked_inputs", "issuer_status" ], record.authenticity_details.keys.sort, "with what it was about"
      assert record.authenticity_confirmed_fake?, model.name
      assert_includes model.authenticity_confirmed_fake, record

      record.record_authenticity!(status: :verified, method: "person", by: manager)
      assert_not record.reload.authenticity_flagged?, "#{model.name}: a person's verified clears it"
    end
  end

  test "record_authenticity! without a person keeps the method; an automatic not found is only flagged for review" do
    MODELS.each do |model|
      record = stored(model, "unchecked", nil)

      travel_to Time.zone.local(2026, 11, 4, 10, 0) do
        record.record_authenticity!(status: "not_found", method: :"automatic:aha_ecards", note: " ", details: nil)
      end
      record.reload

      assert_equal [ "not_found", "automatic:aha_ecards", nil, Time.zone.local(2026, 11, 4, 10, 0) ],
        [ record.authenticity_status, record.authenticity_method, record.authenticity_checked_by, record.authenticity_checked_at ]
      assert_nil record.authenticity_note, "a blank note is stored as nil"
      assert_equal({}, record.authenticity_details)
      assert record.authenticity_flagged_for_review?, model.name
      assert_not record.authenticity_confirmed_fake?
      assert_raises(ActiveRecord::RecordInvalid) { record.record_authenticity!(status: :forged, method: "rules") }
    end
  end

  test "authenticity_attributes copies a check, a person's confirmed fake included, from an item to its certificate" do
    item = stored(ImportItem, "unchecked", nil)
    item.record_authenticity!(status: :mismatch, method: "person", note: "The issuer has another name", by: users(:manager))

    assert_equal %w[authenticity_status authenticity_checked_at authenticity_checked_by_id authenticity_method
      authenticity_note authenticity_details].sort, item.authenticity_attributes.keys.sort
    certificate = stored(Certificate, "unchecked", nil)
    certificate.update!(item.authenticity_attributes)

    assert certificate.reload.authenticity_confirmed_fake?
    assert_equal [ users(:manager), "The issuer has another name" ], [ certificate.authenticity_checked_by, certificate.authenticity_note ]
  end

  # --- A person's fake result whose details change ---

  test "an edit to what a person's Not found was about makes it need a check again, saying what changed" do
    certificate = stored(Certificate, "unchecked", nil)
    certificate.update!(verification_code: "A128")
    certificate.record_authenticity!(status: :not_found, method: "person", by: users(:manager))

    certificate.update!(verification_code: "A12B", verification_url: "https://example.org/verify/A12B", notes: "Retyped")

    assert_equal [ "needs_check", Authenticity::DETAILS_CHANGED_METHOD, nil ],
      [ certificate.authenticity_status, certificate.authenticity_method, certificate.authenticity_checked_by ]
    assert_equal "A person recorded “Not found by issuer”, but the verification code and verification link changed afterwards, " \
      "so it is no longer confirmed fake. Check it with the issuer again.", certificate.authenticity_note
    assert certificate.authenticity_reset_by_last_save?
    assert_not certificate.authenticity_confirmed_fake?
    certificate.update!(notes: "Again")
    assert_not certificate.authenticity_reset_by_last_save?
  end

  test "edits that leave a fake result's details alone keep it, and a Not found ignores the person and dates" do
    certificate = stored(Certificate, "unchecked", nil)
    certificate.record_authenticity!(status: :not_found, method: "person", by: users(:manager))

    certificate.update!(notes: "Asked for the real card", certificate_number: "X-1", completed_on: Date.current - 12)
    certificate.update!(crew_member: crew_members(:li_chen))
    assert certificate.reload.authenticity_confirmed_fake?

    certificate.record_authenticity!(status: :mismatch, method: "person", by: users(:manager))
    certificate.update!(completed_on: Date.current - 14)
    assert_equal [ "needs_check", [ "completion date" ] ], [ certificate.authenticity_status, certificate.authenticity_details["changed"] ]
  end

  test "a result recorded in the same save, an automatic one, or a non-fake one is never reset" do
    certificate = stored(Certificate, "unchecked", nil)
    certificate.record_authenticity!(status: :not_found, method: "automatic:aha_ecards")
    certificate.update!(verification_code: "OTHER")
    assert_equal [ "not_found", "automatic:aha_ecards" ], [ certificate.authenticity_status, certificate.authenticity_method ]

    certificate.update!(verification_code: "THIRD", authenticity_status: "not_found", authenticity_method: "person")
    assert certificate.authenticity_confirmed_fake?, "recorded with the edit, so about the new details"
  end

  test "an import item's fake result is reset by a reviewer's edit or a new reading, not by Read again or a status change" do
    item = stored(ImportItem, "unchecked", nil)
    item.update!(status: :needs_review, proposed_verification_code: "A128")
    item.record_authenticity!(status: :not_found, method: "person", by: users(:manager))

    item.update!(status: :pending, proposed_verification_code: nil) # Read again
    item.update!(status: :extracting)
    item.update!(proposed_verification_code: "A128")
    item.reset_fake_for_new_reading!
    item.update!(status: :needs_review)
    assert item.authenticity_confirmed_fake?, "read again, with the code the person looked up"

    item.update!(proposed_verification_code: "A12C")
    assert_equal [ "needs_check", [ "verification code" ] ], [ item.authenticity_status, item.authenticity_details["changed"] ]
  end

  test "a person's fake result keeps keyed digests of the details it was about, never the details themselves" do
    MODELS.each do |model|
      record = stored(model, "unchecked", nil)
      record.update!(model == Certificate ? { verification_code: "A128" } : { proposed_verification_code: "A128" })
      record.record_authenticity!(status: :mismatch, method: "person", by: users(:manager))

      checked = record.reload.authenticity_details["checked_inputs"]
      assert_equal record.authenticity_inputs.keys.sort, checked.keys.sort, model.name
      assert_equal record.authenticity_inputs.transform_values(&:present?), checked.transform_values(&:present?).slice(*record.authenticity_inputs.keys),
        "a blank is nil"
      assert checked.values.compact.all? { it.match?(/\A\h{32}\z/) }
      [ "A128", record.authenticity_inputs["completion date"]&.iso8601 ].compact.each do |detail|
        assert_not_includes record.authenticity_details.to_json, detail
      end

      record.record_authenticity!(status: :verified, method: "person", by: users(:manager))
      assert_nil record.reload.authenticity_details["checked_inputs"], "only a fake result is reset by an edit"
    end
  end

  test "an edit is compared with the details the person checked, not with whatever was stored since" do
    item = stored(ImportItem, "unchecked", nil)
    item.update!(status: :needs_review, proposed_verification_code: "AB-123")
    item.record_authenticity!(status: :not_found, method: "person", by: users(:manager))
    item.update!(status: :pending, proposed_verification_code: "AB12") # the details drift without an edit
    item.update!(status: :needs_review)

    item.update!(proposed_verification_code: "AB-123") # the reviewer types back the code that was checked
    assert item.authenticity_confirmed_fake?
    assert_not item.authenticity_reset_by_last_save?

    item.update!(proposed_verification_code: "AB-124")
    assert_equal [ "needs_check", [ "verification code" ] ], [ item.authenticity_status, item.authenticity_details["changed"] ]
  end

  test "a new reading resets a person's fake result only when it differs from what they checked" do
    item = stored(ImportItem, "unchecked", nil)
    item.update!(status: :needs_review, proposed_verification_code: "A128", proposed_completed_on: Date.current - 20)
    item.record_authenticity!(status: :not_found, method: "person", note: "No such card", by: users(:manager))

    item.update!(status: :extracting, proposed_completed_on: Date.current - 21)
    item.reset_fake_for_new_reading!
    assert item.authenticity_confirmed_fake?, "a Not found isn't about the dates"

    item.update!(proposed_verification_code: "A12B")
    item.reset_fake_for_new_reading!
    assert_equal [ "needs_check", "details_changed", [ "verification code" ], "No such card" ], [ item.reload.authenticity_status,
      item.authenticity_method, item.authenticity_details["changed"], item.authenticity_details["previous_note"] ]
    assert_nothing_raised { item.reset_fake_for_new_reading! } # nothing fake to reset any more
  end
end
