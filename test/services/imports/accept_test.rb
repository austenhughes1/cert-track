require "test_helper"
require_relative "match_test_support"

class Imports::AcceptTest < ActiveSupport::TestCase
  include ImportsMatchTestSupport
  include ActiveJob::TestHelper

  def accept(item, user: users(:manager), **options)
    Imports::Accept.new(item, user:, **options).call
  end

  test "the image quality flag carries to the certificate" do
    certificate = accept(review_item(type: certificate_types(:flagger), holder_name_raw: "Juan Ortiz", quality_flags: [ "qr_unreadable" ]))

    assert_equal [ "qr_unreadable" ], certificate.quality_flags
    assert certificate.quality_flagged?
  end

  test "creates a verified import certificate from the item's proposals and file" do
    item = review_item(type: certificate_types(:flagger), holder_name_raw: "Juan Ortiz")
    blob = item.file.blob

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
    assert_equal [ blob ], certificate.files.blobs.to_a

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

  test "the certificate takes over the item's file: the item lets go of it, the stored file stays" do
    item = review_item
    blob = item.file.blob

    certificate = accept(item)

    assert_not item.file.attached?
    assert_not item.reload.file.attached?
    assert_equal [ certificate ], ActiveStorage::Attachment.where(blob_id: blob.id).map(&:record)
    assert_equal file_fixture("certificate.jpg").binread, certificate.files.sole.download
  end

  test "deleting an accepted certificate deletes its stored file" do
    item = review_item(import_batch: finished_batch)
    blob = item.file.blob
    certificate = accept(item)

    perform_enqueued_jobs { certificate.destroy! }

    assert_deleted_from_storage blob
    assert item.reload.accepted?
    assert_nil item.certificate
    assert_not item.file.attached?
  end

  test "removing one file from a merged certificate deletes that stored file only" do
    front = review_item(import_batch: finished_batch)
    back = review_item(import_batch: finished_batch, original_filename: "back.png",
      file: { io: StringIO.new(file_fixture("certificate.png").binread), filename: "back.png", content_type: "image/png" })
    front_blob, back_blob = front.file.blob, back.file.blob
    certificate = Imports::Merge.new(front, others: [ back ], user: users(:manager)).call

    perform_enqueued_jobs { certificate.files_attachments.find_by!(blob: back_blob).purge_later }

    assert_deleted_from_storage back_blob
    assert_equal [ front_blob ], certificate.reload.files.blobs.to_a
    assert [ front, back ].none? { |merged| merged.reload.file.attached? }
  end

  test "one photo holding two certificates: each accepted item lets go of its own link only" do
    photo = review_item(import_batch: finished_batch)
    blob = photo.file.blob
    sibling = review_item(import_batch: finished_batch, type: certificate_types(:flagger), sha256: photo.sha256, source_item: photo, file: blob)

    first = accept(photo)

    assert_not photo.reload.file.attached?
    assert_equal blob, sibling.reload.file.blob, "the sibling still waiting for review keeps the photo"
    perform_enqueued_jobs { first.destroy! }
    assert ActiveStorage::Blob.exists?(blob.id), "kept while the sibling still needs it"
    assert_equal file_fixture("certificate.jpg").binread, sibling.reload.file.download

    second = accept(sibling)
    assert_equal [ blob ], second.files.blobs.to_a
    perform_enqueued_jobs { second.destroy! }
    assert_deleted_from_storage blob
  end

  test "an accepted HEIC photo leaves no copy behind once its certificate's files are processed" do
    skip_unless_heif_supported
    item = review_item(import_batch: finished_batch, original_filename: "IMG_0042.HEIC",
      file: { io: file_fixture("certificate.heic").open, filename: "IMG_0042.HEIC", content_type: "image/heic" })
    heic = item.file.blob

    certificate = perform_enqueued_jobs { accept(item) }

    assert_deleted_from_storage heic
    files = certificate.reload.files.blobs.to_a
    assert_equal [ "image/jpeg" ], files.map(&:content_type)
    assert_equal files, ActiveStorage::Blob.all.to_a, "the certificate's files are the only ones stored"
  end

  # --- Phase 3b: issuer, verification code and link, authenticity ---------------------------

  # An item in the queue with an issuer match, a verification code and link, and a check.
  def verified_item(**attrs)
    review_item(matched_certificate_issuer: issuer("REDCROSS"), issuer_match: :matched,
      proposed_verification_code: "TEST123", proposed_verification_url: "https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123",
      authenticity_status: :needs_check, authenticity_method: "rules", authenticity_note: "Open the issuer's page to check it.",
      authenticity_details: { "issuer" => "REDCROSS" }, authenticity_checked_at: 1.hour.ago.round, **attrs)
  end

  test "copies the issuer, verification code and link, and the authenticity check" do
    item = verified_item

    certificate = nil
    assert_no_enqueued_jobs(only: Verification::CheckJob) { certificate = accept(item) }

    assert_equal [ issuer("REDCROSS"), "TEST123", "https://www.redcross.org/take-a-class/qrcode?certnumber=TEST123" ],
      [ certificate.certificate_issuer, certificate.verification_code, certificate.verification_url ]
    assert_equal item.authenticity_attributes, certificate.authenticity_attributes
    assert_equal "Example Safety Training LLC", certificate.issued_by, "issued_by keeps the name as printed"
  end

  test "a flagged item can be accepted by a person: the certificate stays flagged for review and counts by its dates" do
    item = verified_item(authenticity_status: :suspicious, authenticity_method: "qr_link",
      authenticity_note: "The QR code points to a lookalike site.")

    certificate = accept(item)

    assert certificate.authenticity_suspicious?
    assert certificate.authenticity_flagged_for_review?
    assert_equal "The QR code points to a lookalike site.", certificate.authenticity_note
    assert_equal Compliance.status_for_expiry(certificate.expires_on), certificate.compliance_status
    assert_not_equal "fake", certificate.compliance_status
  end

  test "an item a person recorded as not found becomes a confirmed fake certificate" do
    item = verified_item
    item.record_authenticity!(status: :not_found, method: "person", note: "The issuer has no such card.", by: users(:admin))

    certificate = nil
    assert_no_enqueued_jobs(only: Verification::CheckJob) { certificate = accept(item) }

    assert certificate.authenticity_confirmed_fake?
    assert_equal [ "person", users(:admin) ], [ certificate.authenticity_method, certificate.authenticity_checked_by ]
    assert_equal "fake", certificate.compliance_status
  end

  test "accepting with a code typed over the one a person recorded Not found for: needs a check, checked again" do
    item = verified_item(proposed_verification_code: "A128", proposed_verification_url: nil)
    item.record_authenticity!(status: :not_found, method: "person", note: "No such code.", by: users(:admin))

    certificate = nil
    assert_enqueued_jobs(1, only: Verification::CheckJob) { certificate = accept(item, attributes: { verification_code: "A12B" }) }

    assert_enqueued_with(job: Verification::CheckJob, args: [ certificate ])
    assert_equal [ "A12B", "needs_check", "details_changed", nil ],
      [ certificate.verification_code, certificate.authenticity_status, certificate.authenticity_method, certificate.authenticity_checked_by ]
    assert_equal "A person recorded “Not found by issuer”, but the verification code changed afterwards, so it is no longer " \
      "confirmed fake. Check it with the issuer again.", certificate.authenticity_note
    assert_equal({ "previous_status" => "not_found", "previous_checked_by_id" => users(:admin).id,
      "previous_checked_at" => item.authenticity_checked_at.iso8601, "previous_note" => "No such code.", "changed" => [ "verification code" ] },
      certificate.authenticity_details)
    assert_not_equal "fake", certificate.compliance_status
    assert item.reload.authenticity_confirmed_fake?, "the item keeps what the person recorded about it"
  end

  test "the certificate is compared with what the person checked, not with the item's details stored since" do
    item = verified_item(proposed_verification_code: "AB-123", proposed_verification_url: nil)
    item.record_authenticity!(status: :not_found, method: "person", by: users(:admin))
    item.update!(status: :pending, proposed_verification_code: "ZZ999") # Read again, then another reading
    item.update!(status: :needs_review)
    assert item.authenticity_confirmed_fake?

    certificate = accept(item)

    assert_equal [ "ZZ999", "needs_check", [ "verification code" ] ],
      [ certificate.verification_code, certificate.authenticity_status, certificate.authenticity_details["changed"] ],
      "nobody looked ZZ999 up with the issuer"
    assert_not_equal "fake", certificate.compliance_status
  end

  test "a Not found is about the issuer, code and link; a Doesn't match also about the person and dates" do
    other_person = { crew_member_id: crew_members(:maria_garcia).id.to_s }
    not_found = verified_item.tap { it.record_authenticity!(status: :not_found, method: "person", by: users(:admin)) }
    mismatch = verified_item.tap { it.record_authenticity!(status: :mismatch, method: "person", by: users(:admin)) }

    assert accept(not_found, attributes: other_person).authenticity_confirmed_fake?, "the code is made up, whoever holds it"
    certificate = accept(mismatch, attributes: other_person)
    assert_equal [ "needs_check", [ "person" ] ], [ certificate.authenticity_status, certificate.authenticity_details["changed"] ]

    dated = verified_item(proposed_completed_on: nil).tap { it.record_authenticity!(status: :mismatch, method: "person", by: users(:admin)) }
    assert accept(dated, attributes: { completed_on: (Date.current - 40).iso8601 }).authenticity_confirmed_fake?,
      "a blank date wasn't compared, so filling it in changes nothing"
  end

  test "a person's recorded result carries over with who recorded it" do
    item = verified_item
    item.record_authenticity!(status: :verified, method: "person", note: "Checked on the Red Cross site.", by: users(:admin))

    certificate = accept(item)

    assert_equal [ "verified", "person", users(:admin) ],
      [ certificate.authenticity_status, certificate.authenticity_method, certificate.authenticity_checked_by ]
  end

  test "the reviewer may change the issuer, code and link, and the certificate is checked again" do
    item = verified_item
    nof = issuer("NOF")

    certificate = nil
    assert_enqueued_jobs 1, only: Verification::CheckJob do
      certificate = accept(item, attributes: { certificate_issuer_id: nof.id.to_s, verification_code: " NOF-9 ",
        verification_url: "nationaloshafoundation.com/certificate-verification/?certificate_id=NOF-9" })
    end

    assert_equal [ nof, "NOF-9", "https://nationaloshafoundation.com/certificate-verification/?certificate_id=NOF-9" ],
      [ certificate.certificate_issuer, certificate.verification_code, certificate.verification_url ]
    assert_enqueued_with(job: Verification::CheckJob, args: [ certificate ])
  end

  test "each verification field changed on its own checks again, a blank one clears it, and the same values don't" do
    changes = { verification_code: [ "OTHER", "OTHER" ], verification_url: [ "", nil ], certificate_issuer_id: [ "", nil ] }
    changes.each do |field, (value, stored)|
      certificate = nil
      assert_enqueued_jobs(1, only: Verification::CheckJob) { certificate = accept(verified_item, attributes: { field => value }) }
      actual = certificate.public_send(field)
      stored.nil? ? assert_nil(actual, field) : assert_equal(stored, actual, field)
    end

    item = verified_item
    unchanged = { certificate_issuer_id: item.matched_certificate_issuer_id.to_s, verification_code: "TEST123",
      verification_url: "www.redcross.org/take-a-class/qrcode?certnumber=TEST123" }
    assert_no_enqueued_jobs(only: Verification::CheckJob) { accept(item, attributes: unchanged) }
  end

  test "a person accepting takes the suggested issuer they were shown; auto-accept takes only a match" do
    suggested = verified_item(issuer_match: :suggested)
    assert_equal issuer("REDCROSS"), accept(suggested).certificate_issuer

    auto = pdf_item([ certificate_lines(name: "OSHA 30 Hour", holder: "Juan A. Ortiz") ], extraction: nil,
      matched_crew_member: crew_members(:juan_ortiz), matched_certificate_type: certificate_types(:osha30),
      proposed_completed_on: Date.current - 30, matched_certificate_issuer: issuer("REDCROSS"), issuer_match: :suggested,
      proposed_verification_code: "TEST123")
    certificate = Imports::Accept.new(auto, user: nil, auto: true).call
    assert_nil certificate.certificate_issuer
    assert_equal "TEST123", certificate.verification_code
  end

  # The item's check didn't use a merely suggested issuer (Verification::Run trusts only a match),
  # so the certificate that now has it is checked again; a matched one was already used.
  test "accepting a suggested issuer checks the certificate again; a matched one doesn't" do
    suggested = verified_item(issuer_match: :suggested)
    certificate = nil
    assert_enqueued_jobs(1, only: Verification::CheckJob) do
      certificate = accept(suggested, attributes: { certificate_issuer_id: suggested.matched_certificate_issuer_id.to_s })
    end
    assert_enqueued_with(job: Verification::CheckJob, args: [ certificate ])
    clear_enqueued_jobs

    matched = verified_item
    assert_no_enqueued_jobs(only: Verification::CheckJob) do
      accept(matched, attributes: { certificate_issuer_id: matched.matched_certificate_issuer_id.to_s })
    end
  end

  # The item's check compared the card with its printed name or matched member and its dates, so a
  # certificate for someone else, or with corrected dates, is checked again (a borrowed real card
  # mustn't keep "Verified").
  test "another person, a corrected completion date or a different printed expiry checks the certificate again" do
    changes = { crew_member_id: crew_members(:maria_garcia).id.to_s, completed_on: (Date.current - 20).iso8601,
      expires_on: (Date.current + 400).iso8601 }
    changes.each do |field, value|
      certificate = nil
      assert_enqueued_jobs(1, only: Verification::CheckJob) do
        certificate = accept(verified_item(authenticity_status: :verified, authenticity_method: "automatic:aha_ecards"),
          attributes: { field => value })
      end
      assert_enqueued_with(job: Verification::CheckJob, args: [ certificate ])
      clear_enqueued_jobs
    end

    suggested = verified_item(person_match: :suggested)
    assert_enqueued_jobs(1, only: Verification::CheckJob) { accept(suggested) }
  end

  test "an expiry worked out from the type isn't compared, so it doesn't call for another check" do
    item = verified_item(proposed_expires_on: Date.current + 700, proposed_expires_on_source: :computed)

    assert_no_enqueued_jobs(only: Verification::CheckJob) { accept(item) }
  end

  test "a person's recorded result is left alone: changing the person doesn't queue a check" do
    item = verified_item
    item.record_authenticity!(status: :verified, method: "person", note: "Checked by phone.", by: users(:admin))

    assert_no_enqueued_jobs(only: Verification::CheckJob) do
      accept(item, attributes: { crew_member_id: crew_members(:maria_garcia).id.to_s, verification_code: "OTHER" })
    end
  end

  private
    # A batch whose summary was already sent, so accepting its last item sends no email.
    def finished_batch
      @finished_batch ||= ImportBatch.create!(uploaded_by: users(:manager), status: :needs_review, summary_sent_at: 1.hour.ago)
    end

    # The blob row and the stored file are both gone.
    def assert_deleted_from_storage(blob)
      assert_not ActiveStorage::Blob.exists?(blob.id), "#{blob.filename}: blob row kept"
      assert_not blob.service.exist?(blob.key), "#{blob.filename}: stored file kept"
    end

    def skip_unless_heif_supported
      skip "libvips #{Vips.version_string} has no HEIF loader" if Vips.type_find("VipsOperation", "heifload").zero?
    end

    # A flagger card as ProcessExtractionJob leaves it when the expiry text wasn't a date:
    # no proposed expiry, the raw text kept under "unreadable".
    def unreadable_expiry_item(text, type: certificate_types(:flagger), **attrs)
      entry = certificate_entry(code: type.code, name: type.name, completed: "2025-03-14")
        .merge("unreadable" => { "expires_on" => text })
      review_item(type:, extraction: extraction_with(entry), proposed_completed_on: Date.new(2025, 3, 14),
        error_message: %(The expiration date "#{text}" is not a valid YYYY-MM-DD date.), **attrs)
    end
end
