require "test_helper"
require_relative "match_test_support"

class Imports::AcceptTest < ActiveSupport::TestCase
  include ImportsMatchTestSupport
  include ActiveJob::TestHelper

  def accept(item, user: users(:manager), **options)
    Imports::Accept.new(item, user:, **options).call
  end

  test "creates a verified import certificate from the item's proposals and file" do
    item = review_item(type: certificate_types(:flagger), holder_name_raw: "Juan Ortiz")

    certificate = nil
    freeze_time do
      certificate = accept(item)

      assert_equal Time.current, certificate.verified_at
      assert_equal Time.current, item.reload.reviewed_at
    end

    assert certificate.persisted?
    assert certificate.source_import?
    assert_equal [ crew_members(:juan_ortiz), certificate_types(:flagger), item ], [ certificate.crew_member, certificate.certificate_type, certificate.import_item ]
    assert_equal [ item.proposed_completed_on, "30-9990001", "Example Safety Training LLC" ],
      [ certificate.completed_on, certificate.certificate_number, certificate.issued_by ]
    assert_equal users(:manager), certificate.verified_by
    assert_equal [ item.file.blob ], certificate.files.blobs.to_a

    assert item.accepted?
    assert_equal certificate, item.certificate
    assert_equal users(:manager), item.reviewed_by
    assert_includes certificate.import_items, item
  end

  test "supersedes the member's older certificate of the same type" do
    old = certificates(:juan_flagger)
    item = review_item(type: certificate_types(:flagger), proposed_completed_on: old.completed_on + 30)

    certificate = accept(item)

    assert certificate.current?
    assert old.reload.superseded?
    assert_equal certificate, crew_members(:juan_ortiz).current_certificate_for(certificate_types(:flagger))
  end

  test "an older card is kept as history behind the current certificate" do
    current = certificates(:juan_flagger)
    item = review_item(type: certificate_types(:flagger), proposed_completed_on: current.completed_on - 400)

    certificate = accept(item)

    assert certificate.superseded?
    assert current.reload.current?
  end

  test "a printed expiry stays printed" do
    item = review_item(type: certificate_types(:cdl_a), proposed_expires_on: Date.current + 900, proposed_expires_on_source: :printed)

    certificate = accept(item)

    assert_equal Date.current + 900, certificate.expires_on
    assert certificate.expiry_printed?
  end

  test "a computed proposal is re-derived from the final type and completion date" do
    item = review_item(type: certificate_types(:flagger), proposed_completed_on: Date.new(2025, 3, 14),
      proposed_expires_on: Date.new(2028, 3, 14), proposed_expires_on_source: :computed)

    certificate = accept(item, attributes: { certificate_type_id: certificate_types(:first_aid).id, expires_on: "2028-03-14" })

    assert_equal Date.new(2027, 3, 14), certificate.expires_on # first aid: 24 months
    assert certificate.expiry_computed?
  end

  test "a type that never expires gives none" do
    certificate = accept(review_item(type: certificate_types(:osha30), proposed_expires_on_source: :none))

    assert_nil certificate.expires_on
    assert certificate.expiry_none?
  end

  test "attributes override the proposals" do
    item = review_item(type: certificate_types(:flagger), proposed_expires_on: Date.current + 900, proposed_expires_on_source: :printed)

    certificate = accept(item, attributes: ActionController::Parameters.new(
      crew_member_id: crew_members(:li_chen).id.to_s, certificate_type_id: certificate_types(:first_aid).id.to_s,
      completed_on: (Date.current - 5).iso8601, expires_on: (Date.current + 700).iso8601,
      certificate_number: " RC-1 ", issued_by: "Red Cross", ignored: "x"
    ).permit!)

    assert_equal [ crew_members(:li_chen), certificate_types(:first_aid), Date.current - 5, Date.current + 700, "RC-1", "Red Cross" ],
      [ certificate.crew_member, certificate.certificate_type, certificate.completed_on, certificate.expires_on, certificate.certificate_number, certificate.issued_by ]
    assert certificate.expiry_manual?
  end

  test "an unchanged printed expiry in the form stays printed; a cleared one is derived" do
    item = review_item(type: certificate_types(:flagger), proposed_completed_on: Date.new(2025, 3, 14),
      proposed_expires_on: Date.new(2026, 12, 1), proposed_expires_on_source: :printed)
    assert accept(item, attributes: { expires_on: "2026-12-01" }).expiry_printed?

    cleared = review_item(type: certificate_types(:flagger), proposed_completed_on: Date.new(2025, 3, 14),
      proposed_expires_on: Date.new(2026, 12, 1), proposed_expires_on_source: :printed)
    certificate = accept(cleared, attributes: { expires_on: "" })
    assert_equal Date.new(2028, 3, 14), certificate.expires_on
    assert certificate.expiry_computed?
  end

  test "a proposed expiry saved with Save edits (source manual) stays manual" do
    item = review_item(type: certificate_types(:flagger), proposed_completed_on: Date.new(2025, 3, 14),
      proposed_expires_on: Date.new(2027, 8, 30), proposed_expires_on_source: :manual)

    certificate = accept(item, attributes: { expires_on: "2027-08-30" })
    assert_equal Date.new(2027, 8, 30), certificate.expires_on
    assert certificate.expiry_manual?, "not re-derived as computed (flagger: 36 months would give 2028-03-14)"

    untouched = review_item(type: certificate_types(:flagger), proposed_completed_on: Date.new(2025, 3, 14),
      proposed_expires_on: Date.new(2027, 8, 30), proposed_expires_on_source: :manual)
    assert accept(untouched).expiry_manual?
  end

  test "an older proposed expiry with no source was typed by a reviewer, so it is manual too" do
    item = review_item(type: certificate_types(:flagger), proposed_completed_on: Date.new(2025, 3, 14),
      proposed_expires_on: Date.new(2027, 8, 30), proposed_expires_on_source: nil)

    certificate = accept(item, attributes: { expires_on: "2027-08-30" })
    assert_equal Date.new(2027, 8, 30), certificate.expires_on
    assert certificate.expiry_manual?

    untouched = review_item(type: certificate_types(:flagger), proposed_completed_on: Date.new(2025, 3, 14),
      proposed_expires_on: Date.new(2027, 8, 30), proposed_expires_on_source: nil)
    assert accept(untouched).expiry_manual?
  end

  test "a blank override clears the value" do
    certificate = accept(review_item, attributes: { certificate_number: "", issued_by: " " })

    assert_nil certificate.certificate_number
    assert_nil certificate.issued_by
  end

  test "adds the printed spelling as an alias when the matched person was found by a variant" do
    item = review_item(holder_name_raw: "Jaun Ortis", person_match: :suggested)

    accept(item)

    assert_includes crew_members(:juan_ortiz).reload.name_aliases, "Jaun Ortis"
  end

  test "no alias when the reviewer picked a listed candidate the matcher did not propose" do
    item = review_item(member: nil, holder_name_raw: "J. Ortiz", # below the suggestion bar: listed, not proposed
      person_suggestions: [ { "id" => crew_members(:juan_ortiz).id, "name" => "Juan Ortiz", "similarity" => 0.5 } ])

    accept(item, attributes: { crew_member_id: crew_members(:juan_ortiz).id })

    assert_equal crew_members(:juan_ortiz), item.reload.certificate.crew_member
    assert_not_includes crew_members(:juan_ortiz).reload.name_aliases, "J. Ortiz"
  end

  test "no alias for a person picked by hand and saved with Save edits" do
    item = review_item(member: crew_members(:li_chen), holder_name_raw: "Jaun Ortis", person_match: :picked)

    accept(item)

    assert_equal crew_members(:li_chen), item.reload.certificate.crew_member
    assert_not_includes crew_members(:li_chen).reload.name_aliases, "Jaun Ortis"
  end

  test "no alias for a hand pick stored the older way (unmatched with a person)" do
    item = review_item(member: crew_members(:li_chen), holder_name_raw: "Jaun Ortis", person_match: :unmatched)

    accept(item)

    assert_equal crew_members(:li_chen), item.reload.certificate.crew_member
    assert_not_includes crew_members(:li_chen).reload.name_aliases, "Jaun Ortis"
  end

  test "an exact match learns a new printed spelling of the member's name" do
    item = review_item(holder_name_raw: "Juan Ortiz Jr", person_match: :matched)

    accept(item)

    assert_includes crew_members(:juan_ortiz).reload.name_aliases, "Juan Ortiz Jr"
  end

  test "a merged hand-picked item teaches nothing while the matched one does" do
    matched = review_item(holder_name_raw: "Jaun Ortis", person_match: :suggested)
    picked = review_item(holder_name_raw: "J Ortez", person_match: :picked, original_filename: "back.jpg")

    accept(matched, merged_items: [ picked ])

    aliases = crew_members(:juan_ortiz).reload.name_aliases
    assert_includes aliases, "Jaun Ortis"
    assert_not_includes aliases, "J Ortez"
  end

  test "no alias when the spelling normalizes to a known name" do
    item = review_item(holder_name_raw: "ORTIZ, JUAN A")

    assert_no_changes -> { crew_members(:juan_ortiz).reload.name_aliases } do
      accept(item)
    end
  end

  test "no alias when the reviewer chose someone the matcher did not propose" do
    item = review_item(holder_name_raw: "Jaun Ortis") # matched juan_ortiz

    accept(item, attributes: { crew_member_id: crew_members(:li_chen).id })

    assert_not_includes crew_members(:li_chen).reload.name_aliases, "Jaun Ortis"
    assert_not_includes crew_members(:juan_ortiz).reload.name_aliases, "Jaun Ortis"
  end

  test "overriding an exact match with another listed candidate keeps the first member's exact match" do
    ortez = CrewMember.create!(first_name: "Jon", last_name: "Ortez", active: true)
    matched = Imports::PersonMatcher.new("Jon Ortiz").call # juan_ortiz's alias
    assert_equal [ :matched, crew_members(:juan_ortiz) ], [ matched.match, matched.crew_member ]
    assert_includes matched.suggestions.map { _1["id"] }, ortez.id
    item = review_item(holder_name_raw: "Jon Ortiz", person_suggestions: matched.suggestions)

    accept(item, attributes: { crew_member_id: ortez.id })

    assert_equal ortez, item.reload.certificate.crew_member
    assert_empty ortez.reload.name_aliases
    assert_equal [ :matched, crew_members(:juan_ortiz) ], Imports::PersonMatcher.new("Jon Ortiz").call.then { [ _1.match, _1.crew_member ] }
  end

  test "a member created from a card whose spelling is another member's exact name does not take that spelling" do
    item = review_item(holder_name_raw: "Jon Ortiz") # juan_ortiz's alias: the reviewer says this is someone else
    jonathan = Imports::CreateCrewMember.new(item, user: users(:manager), attributes: { first_name: "Jonathan", last_name: "Ortiz" }).call

    accept(item.reload)

    assert_equal jonathan, item.reload.certificate.crew_member
    assert_empty jonathan.reload.name_aliases
    assert_equal [ :matched, crew_members(:juan_ortiz) ], Imports::PersonMatcher.new("Jon Ortiz").call.then { [ _1.match, _1.crew_member ] }
  end

  # --- a printed expiry the AI could not read ---

  test "a card whose printed expiry could not be read is refused until the reviewer types one" do
    item = unreadable_expiry_item("2027-06")

    error = nil
    assert_no_difference -> { Certificate.count } do
      error = assert_raises(ActiveRecord::RecordInvalid) { accept(item) }
    end
    assert_not_kind_of Imports::Accept::NotReviewable, error
    assert_equal [ %(The card's expiry ("2027-06") could not be read. Type the expiry date from the card.) ],
      error.record.errors.full_messages
    assert item.reload.needs_review?

    assert_raises(ActiveRecord::RecordInvalid) { accept(item, attributes: { expires_on: "" }) }
    assert_raises(ActiveRecord::RecordInvalid) { accept(item, attributes: { expires_on: "June 2027" }) }

    certificate = accept(item, attributes: { expires_on: "2027-06-30" })
    assert_equal Date.new(2027, 6, 30), certificate.expires_on
    assert certificate.expiry_manual?
    assert item.reload.accepted?
  end

  test "the refusal lists the certificate's other problems too" do
    item = unreadable_expiry_item("06/2027", member: nil)

    error = assert_raises(ActiveRecord::RecordInvalid) { accept(item) }
    assert_includes error.record.errors.full_messages, "Crew member must exist"
    assert_includes error.record.errors.full_messages, %(The card's expiry ("06/2027") could not be read. Type the expiry date from the card.)
  end

  test "an expiry typed with Save edits counts as the reviewer's" do
    item = unreadable_expiry_item("2027-06", proposed_expires_on: Date.new(2027, 6, 30), proposed_expires_on_source: :manual)

    certificate = accept(item)

    assert_equal Date.new(2027, 6, 30), certificate.expires_on
    assert certificate.expiry_manual?
  end

  test "a never-expiring type does not stand in for an unreadable printed expiry" do
    item = unreadable_expiry_item("Exp 2O27", type: certificate_types(:osha30))

    assert_raises(ActiveRecord::RecordInvalid) { accept(item) }
  end

  test "an unreadable expiry on a merged item blocks a derived expiry as well" do
    front = review_item(type: certificate_types(:flagger), proposed_completed_on: Date.new(2025, 3, 14))
    back = unreadable_expiry_item("2027-06", original_filename: "back.jpg")

    error = assert_raises(ActiveRecord::RecordInvalid) { accept(front, merged_items: [ back ]) }
    assert_match "2027-06", error.message

    certificate = accept(front, merged_items: [ back ], attributes: { expires_on: "2027-06-30" })
    assert_equal 2, certificate.files.count
  end

  test "auto-accept refuses an unreadable expiry as well" do
    item = unreadable_expiry_item("2027-06", status: :extracting)

    assert_raises(ActiveRecord::RecordInvalid) { accept(item, user: nil, auto: true) }
    assert item.reload.extracting?
  end

  test "unreadable_expires_on reads the item's own certificate" do
    item = unreadable_expiry_item("2027-06")
    assert_equal "2027-06", item.unreadable_expires_on

    second = certificate_entry(pages: [ 2 ]).merge("unreadable" => { "expires_on" => "13/13/2027" })
    item.update!(extraction: extraction_with(certificate_entry, second))
    assert_nil item.unreadable_expires_on, "the second certificate belongs to a split-off item"

    item.update!(extraction: nil)
    assert_nil item.unreadable_expires_on
  end

  test "a missing person or type raises RecordInvalid and changes nothing" do
    item = review_item(member: nil, type: nil)

    error = nil
    assert_no_difference -> { Certificate.count } do
      error = assert_raises(ActiveRecord::RecordInvalid) { accept(item) }
    end
    assert_includes error.record.errors.full_messages, "Crew member must exist"
    assert_includes error.record.errors.full_messages, "Certificate type must exist"
    assert item.reload.needs_review?
  end

  test "a bad date from the reviewer raises with the certificate's errors" do
    item = review_item

    error = assert_raises(ActiveRecord::RecordInvalid) do
      accept(item, attributes: { completed_on: (Date.current + 3).iso8601 })
    end
    assert_includes error.message, "Completed on can't be in the future"
    assert item.reload.needs_review?
  end

  test "accepting twice raises NotReviewable" do
    item = review_item
    accept(item)

    error = assert_raises(Imports::Accept::NotReviewable) { accept(ImportItem.find(item.id)) }
    assert_equal [ "This item was already accepted." ], error.record.errors.full_messages
    assert_kind_of ActiveRecord::RecordInvalid, error
    assert_equal 1, Certificate.where(import_item: item).count
  end

  test "the stored status is checked, not the object's" do
    item = review_item
    ImportItem.find(item.id).update!(status: :rejected)

    assert_raises(Imports::Accept::NotReviewable) { accept(item) }
  end

  test "only review-queue items can be accepted by a person" do
    %i[rejected duplicate failed pending extracting].each do |status|
      item = review_item(status:)

      error = assert_raises(Imports::Accept::NotReviewable, status.to_s) { accept(item) }
      assert_predicate error.record.errors[:base], :one?
    end
  end

  test "auto-accept works mid-pipeline without a user" do
    item = review_item(status: :extracting)

    certificate = accept(item, user: nil, auto: true)

    assert_nil certificate.verified_by
    assert_nil certificate.verified_at
    assert item.reload.accepted?
    assert_nil item.reviewed_by
    assert_not_nil item.reviewed_at
  end

  test "a person's accept updates the batch: last review item done -> completed" do
    batch = ImportBatch.create!(uploaded_by: users(:manager), status: :needs_review, summary_sent_at: 1.hour.ago)
    item = review_item(import_batch: batch)

    accept(item)

    assert batch.reload.completed?
    assert_equal 1, batch.accepted_count
    assert_equal 0, batch.review_count
  end

  test "auto-accept leaves the batch to the pipeline" do
    batch = ImportBatch.create!(uploaded_by: users(:manager), status: :processing)
    item = review_item(import_batch: batch, status: :extracting)

    accept(item, user: nil, auto: true)

    assert batch.reload.processing?
  end

  test "accepts a HEIC photo; the certificate gets the same blob" do
    item = review_item
    item.file.attach(io: file_fixture("certificate.heic").open, filename: "IMG_1.heic", content_type: "image/heic")

    certificate = accept(item)

    assert_equal [ "image/heic" ], certificate.files.blobs.map(&:content_type)
    assert_enqueued_with(job: Certificates::ConvertHeicJob, args: [ certificate ])
  end

  private
    # A flagger card as ProcessExtractionJob leaves it when the expiry text wasn't a date:
    # no proposed expiry, the raw text kept under "unreadable".
    def unreadable_expiry_item(text, type: certificate_types(:flagger), **attrs)
      entry = certificate_entry(code: type.code, name: type.name, completed: "2025-03-14")
        .merge("unreadable" => { "expires_on" => text })
      review_item(type:, extraction: extraction_with(entry), proposed_completed_on: Date.new(2025, 3, 14),
        error_message: %(The expiration date "#{text}" is not a valid YYYY-MM-DD date.), **attrs)
    end
end
