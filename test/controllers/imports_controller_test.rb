require "test_helper"

class ImportsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @batch = import_batches(:march_batch)
  end

  # --- access ---

  test "requires sign-in" do
    get imports_path
    assert_redirected_to new_session_path
  end

  test "viewers get 403 on every imports action" do
    sign_in_as users(:viewer)

    get imports_path
    assert_response :forbidden
    get import_path(@batch)
    assert_response :forbidden
    assert_no_difference -> { ImportBatch.count } do
      post imports_path, params: { import: { uploads: [ direct_upload("certificate.pdf") ] } }
    end
    assert_response :forbidden
    assert_no_enqueued_jobs only: Imports::ExpandJob
  end

  test "managers and admins can use imports" do
    %i[manager admin].each do |role|
      sign_in_as users(role)
      get imports_path
      assert_response :success, "#{role} should see imports"
      get import_path(@batch)
      assert_response :success, "#{role} should see a batch"
      sign_out
    end
  end

  # --- index ---

  test "index shows the drop zone, recent batches with counts and the AI status" do
    sign_in_as users(:manager)
    get imports_path

    assert_response :success
    assert_select "title", "Imports · CertTrack"
    assert_select "form#new_import[action=?]", imports_path do
      assert_select "[data-controller=import-drop][data-import-drop-max-bytes-value=?]", 500.megabytes.to_s
      assert_select "input[type=file][multiple][name=?][data-direct-upload-url]", "import[uploads][]"
      assert_select "input[type=file][accept*=?]", ".zip"
      assert_select "input[type=file][accept*=?]", "application/zip"
      assert_select "input[type=file][accept*=?]", ".heic"
    end
    assert_select "#review_queue_link[href=?]", import_reviews_path, text: /1/

    assert_select "turbo-frame#recent_imports" do
      assert_select "tr#import_batch_#{@batch.id}" do
        assert_select "a[href=?]", import_path(@batch)
        assert_select "td", text: users(:manager).display_name
        assert_select "[data-status=needs_review]"
        assert_select "td[data-count=accepted]", "1"
        assert_select "td[data-count=needs_review]", "1"
        assert_select "td[data-count=duplicate]", "1"
        assert_select "td[data-count=failed]", "0"
      end
      # Nothing is being read, so the table doesn't refresh itself.
      assert_select "[data-controller=frame-refresh]", count: 0
    end

    assert_select "#ai_provider", /Fake provider/
    assert_select "#ai_ready", /Models configured/
    assert_select "#ai_budget", /0\s+of\s+9,000\s+neurons/
    assert_select "#ai_waiting", count: 0
  end

  test "index shows today's UTC AI use and items waiting for the 00:05 UTC reset" do
    travel_to Time.utc(2026, 11, 4, 3, 0) do # 8 PM on Nov 3 in Denver: the UTC day is already Nov 4
      AiUsageDay.record!(provider: "fake", units: 9_000, day: Date.new(2026, 11, 4))
      AiUsageDay.record!(provider: "fake", units: 4_000, day: Date.new(2026, 11, 3))
      batch = ImportBatch.create!(uploaded_by: users(:manager), status: :processing, files_count: 1)
      waiting = new_item(batch:, status: :extracting, next_attempt_at: Ai::Budget.next_reset_at)
      sign_in_as users(:manager)

      get imports_path

      assert_select "#ai_budget", /9,000\s+of\s+9,000\s+neurons used, the daily budget is used up/
      assert_select "#ai_waiting", /1 item waiting for the 00:05 UTC reset/
      assert_select "#ai_waiting time[datetime=?]", waiting.next_attempt_at.in_time_zone.iso8601
      # A batch still being read keeps the recent-batches frame refreshing.
      assert_select "turbo-frame#recent_imports [data-controller=frame-refresh][data-frame-refresh-interval-value=?]", "3000"
    end
  end

  test "index lists what to set when the AI provider is not configured" do
    sign_in_as users(:manager)
    with_env("CLOUDFLARE_ACCOUNT_ID" => nil, "CLOUDFLARE_AI_API_TOKEN" => nil, "EXTRACTION_MODEL" => nil) do
      Ai::Config.with(provider: "workers_ai") { get imports_path }
    end

    assert_response :success
    assert_select "#ai_provider", "Cloudflare Workers AI"
    assert_select "#ai_ready", /Not configured/
    assert_select "#ai_problems li", minimum: 1
    assert_select "#ai_problems", /CLOUDFLARE_AI_API_TOKEN/
  end

  test "index shows an empty state with no batches" do
    ImportBatch.destroy_all
    sign_in_as users(:manager)
    get imports_path

    assert_select "turbo-frame#recent_imports", /No imports yet/
    assert_select "#import_batches", count: 0
  end

  # --- create ---

  test "create makes a receiving batch from direct uploads and enqueues the expand job" do
    sign_in_as users(:manager)
    pdf = direct_upload("certificate.pdf", content_type: "application/pdf")
    zip = direct_upload_data(zip_bytes, filename: "crew.zip", content_type: "application/zip")
    heic = direct_upload("certificate.heic", content_type: "") # some browsers send no type for HEIC

    assert_difference -> { ImportBatch.count }, 1 do
      post imports_path, params: { import: { uploads: [ "", pdf, zip, heic ] } }
    end

    batch = ImportBatch.order(:id).last
    assert_redirected_to import_path(batch)
    assert_equal users(:manager), batch.uploaded_by
    assert batch.receiving?
    assert_equal %w[certificate.heic certificate.pdf crew.zip], batch.uploads.map { |upload| upload.filename.to_s }.sort
    assert_enqueued_with job: Imports::ExpandJob, args: [ batch ]
    assert_equal "Uploaded 3 files. Reading them now; this page updates as it goes.", flash[:notice]
  end

  test "create accepts zips labelled the Windows way" do
    sign_in_as users(:manager)
    zip = direct_upload_data(zip_bytes, filename: "CREW CARDS", content_type: "application/x-zip-compressed")

    assert_difference -> { ImportBatch.count }, 1 do
      post imports_path, params: { import: { uploads: [ zip ] } }
    end
  end

  test "create with no files re-renders with an error" do
    sign_in_as users(:manager)

    assert_no_difference -> { ImportBatch.count } do
      post imports_path, params: { import: { uploads: [ "" ] } }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /Choose at least one file or zip/
    assert_no_enqueued_jobs only: Imports::ExpandJob

    post imports_path
    assert_response :unprocessable_entity
  end

  test "create refuses a batch over 500 MB and carries nothing over" do
    sign_in_as users(:manager)
    big = direct_upload("certificate.pdf")
    ActiveStorage::Blob.find_signed!(big).update_columns(byte_size: 400.megabytes)
    other = direct_upload("certificate.jpg")
    ActiveStorage::Blob.find_signed!(other).update_columns(byte_size: 200.megabytes)

    assert_no_difference -> { ImportBatch.count } do
      post imports_path, params: { import: { uploads: [ big, other ] } }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /These files add up to 600 MB; a batch can be at most 500 MB/
    assert_select "#carried_over_uploads", count: 0
    assert_no_enqueued_jobs only: Imports::ExpandJob
  end

  test "create refuses unsupported files and offers the good uploads again" do
    sign_in_as users(:manager)
    pdf = direct_upload("certificate.pdf")
    text = direct_upload("notes.txt", content_type: "text/plain")

    assert_no_difference -> { ImportBatch.count } do
      post imports_path, params: { import: { uploads: [ pdf, text ] } }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /notes.txt isn't a PDF, JPG, PNG, HEIC, WEBP or zip file/
    assert_select "#carried_over_uploads input[type=checkbox][checked][name=?][value=?]", "import[uploads][]",
      ActiveStorage::Blob.find_signed!(pdf).signed_id
    assert_select "#carried_over_uploads", text: /notes.txt/, count: 0

    # Submitting the carried-over upload alone works without uploading it again.
    post imports_path, params: { import: { uploads: [ "", ActiveStorage::Blob.find_signed!(pdf).signed_id ] } }
    assert_redirected_to import_path(ImportBatch.order(:id).last)
  end

  test "create refuses tampered or unknown upload ids" do
    sign_in_as users(:manager)

    assert_no_difference -> { ImportBatch.count } do
      post imports_path, params: { import: { uploads: [ "not-a-signed-id", direct_upload("certificate.pdf") ] } }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /didn't finish uploading/
  end

  test "create refuses an upload whose bytes never arrived instead of failing" do
    sign_in_as users(:manager)
    data = file_fixture("certificate.pdf").binread
    unfinished = ActiveStorage::Blob.create_before_direct_upload!(filename: "certificate.pdf", byte_size: data.bytesize,
      checksum: OpenSSL::Digest::MD5.base64digest(data), content_type: "application/pdf")
    finished = direct_upload("certificate.jpg")

    assert_no_difference -> { ImportBatch.count } do
      post imports_path, params: { import: { uploads: [ unfinished.signed_id, finished ] } }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /didn't finish uploading/
    assert_select "#carried_over_uploads input[value=?]", finished
    assert_select "#carried_over_uploads input[value=?]", unfinished.signed_id, count: 0
  end

  test "create identifies an upload the browser left untyped from its bytes" do
    sign_in_as users(:manager)

    post imports_path, params: { import: { uploads: [ direct_upload("certificate.pdf", content_type: "application/octet-stream") ] } }

    batch = ImportBatch.order(:id).last
    assert_redirected_to import_path(batch)
    assert_equal [ "application/pdf" ], batch.uploads.map { |upload| upload.blob.content_type }
  end

  test "create refuses more files than a batch holds" do
    sign_in_as users(:manager)
    uploads = %w[certificate.pdf certificate.jpg certificate.png].map { |name| direct_upload(name) }

    Imports::Config.with(max_entries: 2) do
      assert_no_difference -> { ImportBatch.count } do
        post imports_path, params: { import: { uploads: uploads } }
      end
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /That's 3 files; a batch holds at most 2/
  end

  # --- show ---

  test "show renders every item status with its details and refreshes while items are in flight" do
    batch = ImportBatch.create!(uploaded_by: users(:admin), status: :processing, files_count: 7,
      error_message: "crew.zip/evil.pdf: unsafe path, skipped.")
    certificate = certificates(:juan_osha30)
    items = {
      pending: new_item(batch:, status: :pending, original_filename: "crew.zip/a.pdf"),
      extracting: new_item(batch:, status: :extracting, original_filename: "crew.zip/b.pdf"),
      waiting: new_item(batch:, status: :extracting, original_filename: "crew.zip/c.pdf", next_attempt_at: 1.hour.from_now),
      needs_review: new_item(batch:, status: :needs_review, original_filename: "scan.pdf", page_range: "2-3",
        matched_crew_member: crew_members(:juan_ortiz), person_match: :suggested,
        matched_certificate_type: certificate_types(:osha30), type_match: :matched, confidence: 0.72),
      accepted: new_item(batch:, status: :accepted, original_filename: "scan.pdf", page_range: "1",
        certificate:, matched_crew_member: crew_members(:juan_ortiz), person_match: :matched, confidence: 0.95),
      rejected: new_item(batch:, status: :rejected, original_filename: "outline.pdf", rejection_reason: "Not a certificate"),
      duplicate: new_item(batch:, status: :duplicate, original_filename: "scan (1).pdf", page_range: "1",
        duplicate_of: import_items(:accepted_li_flagger)),
      failed: new_item(batch:, status: :failed, original_filename: "broken.pdf", error_message: "pdftotext timed out"),
      unsafe: new_item(batch:, status: :rejected, sha256: nil, original_filename: "crew.zip/../evil.pdf",
        rejection_reason: "Unsafe path inside the zip")
    }
    sign_in_as users(:manager)

    get import_path(batch)

    assert_response :success
    assert_select "title", "Import batch ##{batch.id} · CertTrack"
    assert_select "turbo-frame#import_batch_progress[target=_top]" do
      assert_select "[data-controller=frame-refresh][data-frame-refresh-interval-value=?]", "3000"
      assert_select "#batch_error", /unsafe path/
      assert_select "#count_pending [data-count]", "1"
      assert_select "#count_extracting [data-count]", "2"
      assert_select "#count_waiting_for_budget [data-count]", "1"
      assert_select "#count_rejected [data-count]", "2"
      assert_select "#batch_status_text", /Reading files: 6 of 9 items done/
    end

    expected = {
      pending: "Queued", extracting: "Reading", waiting: "Waiting for AI budget", needs_review: "Needs review",
      accepted: "Accepted", rejected: "Rejected", duplicate: "Duplicate", failed: "Failed", unsafe: "Rejected"
    }
    expected.each do |key, label|
      assert_select "tr#import_item_#{items.fetch(key).id} [data-status]", label
    end

    assert_select "tr#import_item_#{items[:needs_review].id}" do
      assert_select "td", /p\. 2-3/
      assert_select "a[href=?]", crew_member_path(crew_members(:juan_ortiz)), text: "Juan Ortiz"
      assert_select "td", /\(suggested\)/
      assert_select "td", /OSHA 30 Construction/
      assert_select "td", "72%"
      assert_select "a[href=?]", import_review_path(items[:needs_review]), text: "Review"
    end
    assert_select "a[href=?]", import_review_path(items[:needs_review]), text: "Review these"
    assert_select "tr#import_item_#{items[:accepted].id} a[href=?]",
      crew_member_certificate_path(certificate.crew_member_id, certificate), text: "View certificate"
    assert_select "tr#import_item_#{items[:rejected].id}", /Not a certificate/
    assert_select "tr#import_item_#{items[:unsafe].id}", /Unsafe path inside the zip/
    assert_select "tr#import_item_#{items[:failed].id}", /pdftotext timed out/
    assert_select "tr#import_item_#{items[:duplicate].id}", /Same file as scan_0001.pdf \(p\. 1\)/
    assert_select "tr#import_item_#{items[:duplicate].id} a[href=?]", import_path(@batch)
    assert_select "tr#import_item_#{items[:waiting].id}", /Continues/
    assert_select "tr#import_item_#{items[:pending].id} a", text: "Review", count: 0
  end

  test "show slows the refresh when everything left waits for the AI reset" do
    batch = ImportBatch.create!(uploaded_by: users(:manager), status: :processing, files_count: 1)
    new_item(batch:, status: :extracting, next_attempt_at: Ai::Budget.next_reset_at)
    sign_in_as users(:manager)

    get import_path(batch)

    assert_select "[data-controller=frame-refresh][data-frame-refresh-interval-value=?]", "60000"
    assert_select "#batch_status_text", /continue after 00:05 UTC/
  end

  test "show stops refreshing once the batch is done" do
    sign_in_as users(:manager)
    get import_path(@batch)

    assert_select "#batch_progress[data-live=false]"
    assert_select "[data-controller=frame-refresh]", count: 0
    assert_select "#batch_status_text", /Finished reading. 1 item needs review/
    assert_select "a[href=?]", import_review_path(import_items(:review_juan_first_aid)), text: "Review these"
  end

  test "show of a batch with nothing in it yet" do
    batch = ImportBatch.create!(uploaded_by: users(:manager), status: :receiving)
    sign_in_as users(:manager)
    get import_path(batch)

    assert_response :success
    assert_select "#batch_status_text", /Waiting to unpack/
    assert_select "[data-controller=frame-refresh]"
    assert_select "#batch_progress", /Nothing found yet/
  end

  test "show of a completed batch" do
    batch = ImportBatch.create!(uploaded_by: users(:manager), status: :completed, files_count: 1)
    new_item(batch:, status: :rejected, rejection_reason: "Not a certificate")
    sign_in_as users(:manager)
    get import_path(batch)

    assert_select "#batch_status_text", /Every file is accounted for/
    assert_select "a", text: "Review these", count: 0
  end

  private
    def new_item(batch: @batch, status:, sha256: SecureRandom.hex(32), **attributes)
      ImportItem.create!(import_batch: batch, status: status, sha256: sha256, original_filename: "card.pdf", **attributes)
    end

    # What the browser does: create the blob first, PUT the bytes, then submit the signed id.
    def direct_upload(name, content_type: nil)
      direct_upload_data(file_fixture(name).binread, filename: name, content_type: content_type)
    end

    def direct_upload_data(data, filename:, content_type: nil)
      blob = ActiveStorage::Blob.create_before_direct_upload!(
        filename: filename, byte_size: data.bytesize, checksum: OpenSSL::Digest::MD5.base64digest(data), content_type: content_type
      )
      blob.service.upload(blob.key, StringIO.new(data))
      blob.signed_id
    end

    def zip_bytes
      require "zip"
      Zip::OutputStream.write_buffer do |zip|
        zip.put_next_entry("cards/ortiz.pdf")
        zip.write(file_fixture("certificate.pdf").binread)
      end.string
    end

    def with_env(values)
      previous = values.keys.index_with { |key| ENV[key] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| ENV[key] = value }
    end
end
