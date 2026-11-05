require "test_helper"
require_relative "../../services/verification/verification_test_support"

class Verification::CheckJobTest < ActiveJob::TestCase
  include VerificationTestSupport

  AHA_CODE = "212345678901".freeze

  setup do
    seed_issuers
    @batch = ImportBatch.create!(uploaded_by: users(:manager), status: :processing)
  end

  def aha_item(**attrs)
    ImportItem.create!({ import_batch: @batch, status: :needs_review, sha256: SecureRandom.hex(32), original_filename: "card.jpg",
      holder_name_raw: "Juan Ortiz", matched_certificate_issuer: issuer("AHA"), issuer_match: :matched,
      proposed_verification_code: AHA_CODE, proposed_completed_on: Date.new(2025, 3, 14) }.merge(attrs))
  end

  # A printed expiry two years after its completion date (which moves with today, see
  # certificates.yml), so the AHA site's renewal month is compared with it.
  def aha_certificate
    certificates(:juan_first_aid).tap do |certificate|
      certificate.update!(certificate_issuer: issuer("AHA"), verification_code: AHA_CODE, expires_on: certificate.completed_on >> 24,
        expires_on_source: :printed)
    end
  end

  # Performs the job with automatic checks on and the issuer's site answering every request with
  # the given page; an AHA page's renewal month (03/2027) becomes aha_certificate's. Returns the FakeTransport.
  def perform_online(record, page_name = "aha_ecards_found", cache: ActiveSupport::Cache::MemoryStore.new, **options)
    renewal = (certificates(:juan_first_aid).completed_on >> 24).strftime("%m/%Y")
    with_fake_sites(responder: ->(*) { response(page(page_name).sub("03/2027", renewal)) }, cache: cache) do
      with_auto_checks { Verification::CheckJob.perform_now(record, **options) }
    end
  end

  test "runs on the import worker's queue (reading QR codes is CPU work)" do
    assert_enqueued_with(job: Verification::CheckJob, queue: "imports", args: [ aha_item ]) do
      Verification::CheckJob.perform_later(ImportItem.last)
    end
  end

  test "asks the issuer's site and records the result" do
    certificate = aha_certificate

    transport = perform_online(certificate)

    assert_equal 1, transport.requests.size
    assert_equal [ "verified", "automatic:aha_ecards" ], [ certificate.reload.authenticity_status, certificate.authenticity_method ]
  end

  test "with automatic checks off, nothing is sent and a person is asked to check" do
    certificate = aha_certificate

    transport = with_fake_sites { Verification::CheckJob.perform_now(certificate) }

    assert_empty transport.requests
    assert_equal [ "needs_check", "rules" ], [ certificate.reload.authenticity_status, certificate.authenticity_method ]
  end

  test "a person's result stays unless forced (Check again)" do
    certificate = aha_certificate
    certificate.record_authenticity!(status: :not_found, method: "person", by: users(:manager))

    transport = perform_online(certificate)
    assert_empty transport.requests
    assert_equal "person", certificate.reload.authenticity_method

    perform_online(certificate, force: true)
    assert_equal [ "verified", "automatic:aha_ecards" ], [ certificate.reload.authenticity_status, certificate.authenticity_method ]
    assert_nil certificate.authenticity_checked_by
  end

  test "an accepted item's certificate is checked again too" do
    certificate = aha_certificate
    item = aha_item(status: :accepted, certificate: certificate)

    perform_online(item)

    assert_equal "verified", item.reload.authenticity_status
    assert_equal "needs_check", certificate.reload.authenticity_status, "the site was asked moments ago for the item"
    assert_equal "busy", certificate.authenticity_details["unavailable"]
    assert_enqueued_with job: Verification::CheckJob, args: [ certificate, { attempt: 1 } ]

    travel 6.seconds
    perform_online(certificate, attempt: 1)
    assert_equal "verified", certificate.reload.authenticity_status
  end

  test "Check again forces the item, never its certificate: a person's result on the certificate stays" do
    certificate = aha_certificate
    certificate.record_authenticity!(status: :not_found, method: "person", by: users(:manager))
    item = aha_item(status: :accepted, certificate: certificate)

    perform_online(item, force: true, requested_at: Time.current)

    assert_equal "verified", item.reload.authenticity_status
    assert_equal [ "not_found", "person" ], [ certificate.reload.authenticity_status, certificate.authenticity_method ]
  end

  test "a person's Not found recorded after Check again was pressed, then accepted, stays confirmed fake" do
    item = aha_item(matched_crew_member: crew_members(:juan_ortiz), person_match: :matched,
      matched_certificate_type: certificate_types(:first_aid), type_match: :matched)
    Verification::CheckJob.perform_later(item, force: true, requested_at: Time.current)
    travel 1.minute # the imports worker is busy with OCR
    item.record_authenticity!(status: :not_found, method: "person", note: "No such eCard", by: users(:manager))
    certificate = Imports::Accept.new(item, user: users(:manager)).call
    assert certificate.authenticity_confirmed_fake?

    transport = with_fake_sites(responder: ->(*) { response(page("aha_ecards_found")) }) do
      with_auto_checks { perform_enqueued_jobs(only: Verification::CheckJob) }
    end

    assert_empty transport.requests
    assert item.reload.authenticity_confirmed_fake?
    assert certificate.reload.authenticity_confirmed_fake?
    assert_equal [ "fake", "No such eCard" ], [ certificate.compliance_status, certificate.authenticity_note ]
  end

  test "an item accepted while the issuer's site was asked: its certificate is checked too" do
    item = aha_item(matched_crew_member: crew_members(:juan_ortiz), person_match: :matched,
      matched_certificate_type: certificate_types(:first_aid), type_match: :matched, proposed_completed_on: Date.current - 30)
    run = Verification::Run.new(item, network: false) # as Imports::ProcessExtractionJob leaves it
    with_auto_checks { run.call }
    assert run.automatic_check_deferred?
    job_copy = ImportItem.find(item.id)
    certificate = nil
    accept_meanwhile = lambda do |*|
      certificate ||= Imports::Accept.new(ImportItem.find(item.id), user: users(:manager)).call
      response(page("aha_ecards_invalid"))
    end

    cache = ActiveSupport::Cache::MemoryStore.new
    with_fake_sites(responder: accept_meanwhile, cache: cache) { with_auto_checks { Verification::CheckJob.perform_now(job_copy) } }

    assert item.reload.accepted?
    assert_equal [ "not_found", "automatic:aha_ecards" ], [ item.authenticity_status, item.authenticity_method ]
    assert_equal "busy", certificate.reload.authenticity_details["unavailable"], "checked too: the site was asked moments ago"
    assert_enqueued_with job: Verification::CheckJob, args: [ certificate, { attempt: 1 } ]

    travel 6.seconds
    with_fake_sites(responder: accept_meanwhile, cache: cache) { with_auto_checks { perform_enqueued_jobs(only: Verification::CheckJob) } }
    assert_equal [ "not_found", "automatic:aha_ecards" ], [ certificate.reload.authenticity_status, certificate.authenticity_method ],
      "the issuer's answer reaches the certificate, not just the accepted item"
    assert certificate.authenticity_flagged_for_review?
  end

  test "an item still in review has no certificate to check" do
    item = aha_item

    transport = perform_online(item)

    assert_equal 1, transport.requests.size
    assert_equal "verified", item.reload.authenticity_status
  end

  test "busy: tried again later without force, so a person's result recorded meanwhile stays" do
    cache = ActiveSupport::Cache::MemoryStore.new
    cache.write("verification/http/ecards.heart.org/recent", true, expires_in: 5.seconds)
    certificate = aha_certificate

    perform_online(certificate, cache: cache, force: true)

    assert_equal "needs_check", certificate.reload.authenticity_status
    assert_enqueued_with job: Verification::CheckJob, args: [ certificate, { attempt: 1 } ]

    certificate.record_authenticity!(status: :verified, method: "person", by: users(:manager))
    transport = perform_online(certificate, attempt: 1)
    assert_empty transport.requests
    assert_equal "person", certificate.reload.authenticity_method
  end

  test "busy_wait is past the 5-second interval and grows with each attempt" do
    assert_operator Verification::CheckJob.busy_wait(0), :>, 5.seconds
    assert_operator Verification::CheckJob.busy_wait(0), :<=, 11.seconds
    assert_operator Verification::CheckJob.busy_wait(4), :<=, (6 + (5 * 16)).seconds
  end

  test "a deleted record discards the job" do
    item = aha_item
    Verification::CheckJob.perform_later(item)
    item.destroy!

    assert_nothing_raised { perform_enqueued_jobs(only: Verification::CheckJob) }
  end

  test "an unexpected error records nothing and is raised for the jobs dashboard" do
    certificate = aha_certificate
    certificate.record_authenticity!(status: :needs_check, method: "rules", note: "Before")

    error = assert_raises(RuntimeError) do
      with_fake_sites(responder: ->(*) { raise "parser bug" }) do
        with_auto_checks { Verification::CheckJob.perform_now(certificate) }
      end
    end

    assert_equal "parser bug", error.message
    assert_equal [ "needs_check", "Before" ], [ certificate.reload.authenticity_status, certificate.authenticity_note ]
  end

  test "a certificate's QR codes are read from its files" do
    skip "zbarimg is not installed" unless Certificates::QrReader.available?

    certificate = certificates(:juan_osha30)
    certificate.update!(certificate_issuer: issuer("REDCROSS"), verification_code: "TEST123")
    certificate.files.attach(io: file_fixture("qr/lookalike_qr.png").open, filename: "card.png", content_type: "image/png")

    Verification::CheckJob.perform_now(certificate)

    assert_equal "suspicious", certificate.reload.authenticity_status
    assert_equal "redcross-verify.com", certificate.authenticity_details["qr_host"]
  end

  test "a certificate without files is checked with its code and link" do
    certificate = certificates(:juan_osha30)
    certificate.update!(certificate_issuer: issuer("REDCROSS"), verification_code: "TEST123")

    Verification::CheckJob.perform_now(certificate)

    assert_equal "needs_check", certificate.reload.authenticity_status
  end

  # --- The job's copy of a certificate goes stale while it reads QR codes and asks the issuer ---

  # A crew member with no flagger certificates yet, and their current ones of that type.
  def flagger_holder
    @holder ||= CrewMember.create!(first_name: "Stale", last_name: "Copy")
  end

  def flagger(member = flagger_holder, **attrs)
    Certificate.create!(crew_member: member, certificate_type: certificate_types(:flagger), **attrs)
  end

  def current_flaggers(member = flagger_holder)
    Certificate.current.where(crew_member: member, certificate_type: certificate_types(:flagger)).pluck(:id)
  end

  def record_fake(certificate)
    certificate.reload.record_authenticity!(status: :not_found, method: "person", by: users(:manager))
  end

  test "Check again on a copy loaded before a genuine card was added leaves that genuine card current" do
    fake = flagger(completed_on: Date.current - 30, verification_code: "A1")
    record_fake(fake)
    clicked_at = Time.current
    job_copy = Certificate.find(fake.id)
    travel 1.second
    genuine = flagger(completed_on: Date.current - 300)
    assert_equal [ genuine.id ], current_flaggers, "the genuine card outranks the confirmed fake one"

    Verification::CheckJob.perform_now(job_copy, force: true, requested_at: clicked_at)

    assert_equal [ "needs_check", "rules" ], [ fake.reload.authenticity_status, fake.authenticity_method ]
    assert_equal [ fake.id ], current_flaggers, "no longer confirmed fake, and the newer one: exactly one current"
    assert genuine.reload.superseded?
  end

  test "two overlapping Check again jobs in one group leave exactly one current certificate" do
    older = flagger(completed_on: Date.current - 300, verification_code: "A1")
    newer = flagger(completed_on: Date.current - 30, verification_code: "B2")
    [ older, newer ].each { record_fake(it) }
    assert_equal [ newer.id ], current_flaggers
    clicked_at = Time.current
    travel 1.second

    newer_copy = Certificate.find(newer.id) # the second job has started
    Verification::CheckJob.perform_now(Certificate.find(older.id), force: true, requested_at: clicked_at)
    assert_equal [ older.id ], current_flaggers, "the only one no longer confirmed fake"
    Verification::CheckJob.perform_now(newer_copy, force: true, requested_at: clicked_at)

    assert_equal [ newer.id ], current_flaggers
  end

  test "a certificate deleted while its check ran: nothing is written and the genuine one stays current" do
    genuine = flagger(completed_on: Date.current - 300)
    fake = flagger(completed_on: Date.current - 30, verification_code: "A1")
    record_fake(fake)
    clicked_at = Time.current
    job_copy = Certificate.find(fake.id)
    travel 1.second
    Certificate.find(fake.id).destroy!

    assert_nil Verification::Run.new(job_copy, force: true, requested_at: clicked_at).call
    assert_equal [ genuine.id ], current_flaggers
  end

  test "a certificate moved to another person while its check ran is ranked in that person's group" do
    other = CrewMember.create!(first_name: "Other", last_name: "Holder")
    genuine = flagger(completed_on: Date.current - 300)
    others_genuine = flagger(other, completed_on: Date.current - 400)
    fake = flagger(completed_on: Date.current - 30, verification_code: "A1")
    record_fake(fake)
    clicked_at = Time.current
    job_copy = Certificate.find(fake.id)
    travel 1.second
    Certificate.find(fake.id).update!(crew_member: other) # a Not found isn't about the person: still fake
    assert_equal [ others_genuine.id ], current_flaggers(other)

    assert_nothing_raised { Verification::CheckJob.perform_now(job_copy, force: true, requested_at: clicked_at) }

    assert_equal [ genuine.id ], current_flaggers, "the first person keeps their genuine card"
    assert_equal [ fake.id ], current_flaggers(other), "no longer confirmed fake, and newer than the other person's card"
    assert_equal other, fake.reload.crew_member
  end
end
