require "test_helper"
require "support/import_samples"

class Imports::AiExtractJobTest < ActiveJob::TestCase
  include ActiveSupport::Testing::TimeHelpers

  AI_ENV = %w[CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_AI_API_TOKEN EXTRACTION_MODEL EXTRACTION_VISION_MODEL OLLAMA_URL].freeze
  AFTERNOON_UTC = Time.utc(2026, 11, 3, 15, 30)
  NEXT_RESET = Time.utc(2026, 11, 4, 0, 5)

  setup do
    AiUsageDay.delete_all
    @saved_env = AI_ENV.index_with { |name| ENV[name] }
    AI_ENV.each { |name| ENV.delete(name) }
    @batch = ImportBatch.create!(uploaded_by: users(:manager), status: :processing)
  end

  teardown do
    @saved_env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    Ai::FakeProvider.reset!
  end

  test "stores the normalized extraction and hands the item to step 5" do
    item = extracting_item(ImportSamples.certificate_text(holder: "Li Chen"), ImportSamples.outline_text)

    assert_enqueued_with(job: Imports::ProcessExtractionJob, args: [ item ]) do
      Imports::AiExtractJob.perform_now(item)
    end

    item.reload
    assert item.extracting?, "step 5 decides the status"
    assert_equal [ "Li Chen" ], item.extraction["certificates"].map { |certificate| certificate["holder_name"] }
    assert_equal [ 2 ], item.extraction["non_certificate_pages"]
    assert_equal "fake", item.provider
    assert_operator item.ai_units_used, :>, 0
    assert_equal 1, item.attempts
    assert_nil item.next_attempt_at
    assert_equal item.ai_units_used, Ai::Budget.used_today("fake")
  end

  test "a second read of an item adds its AI units to the first one's" do
    item = extracting_item(ImportSamples.certificate_text)
    item.update!(ai_units_used: 140) # an earlier read (Imports::Reread keeps it)

    Imports::AiExtractJob.perform_now(item)

    assert_equal 140 + Ai::Budget.used_today("fake"), item.reload.ai_units_used
  end

  test "a simulated quota error reschedules the job for exactly 00:05 UTC the next day" do
    item = extracting_item(ImportSamples.certificate_text)
    Ai::FakeProvider.fail_next!

    travel_to AFTERNOON_UTC do
      assert_enqueued_with(job: Imports::AiExtractJob, args: [ item ], at: NEXT_RESET) do
        Imports::AiExtractJob.perform_now(item)
      end
    end

    item.reload
    assert_equal NEXT_RESET, item.next_attempt_at
    assert item.extracting?
    assert_nil item.extraction
    assert item.waiting_for_budget?(AFTERNOON_UTC)
    assert_no_enqueued_jobs(only: Imports::ProcessExtractionJob)
  end

  test "late evening in Denver is already the next UTC day, so the wait is for the reset after that" do
    denver_evening = Time.find_zone("America/Denver").local(2026, 11, 3, 18, 30) # 01:30 UTC on Nov 4
    item = extracting_item(ImportSamples.certificate_text)
    Ai::FakeProvider.fail_next!

    travel_to denver_evening do
      assert_enqueued_with(job: Imports::AiExtractJob, args: [ item ], at: Time.utc(2026, 11, 5, 0, 5)) do
        Imports::AiExtractJob.perform_now(item)
      end
    end
  end

  test "a quota error just after midnight UTC parks the item until 00:05 that day, and it runs then" do
    item = extracting_item(ImportSamples.certificate_text)
    Ai::FakeProvider.fail_next!
    reset = Time.utc(2026, 11, 4, 0, 5)

    travel_to Time.utc(2026, 11, 4, 0, 2) do
      assert_enqueued_with(job: Imports::AiExtractJob, args: [ item ], at: reset) do
        Imports::AiExtractJob.perform_now(item)
      end
    end
    assert_equal reset, item.reload.next_attempt_at

    travel_to reset + 1.second do
      assert_enqueued_with(job: Imports::ProcessExtractionJob, args: [ item ]) do
        Imports::AiExtractJob.perform_now(item)
      end
    end
    assert_nil item.reload.next_attempt_at
    assert Imports::Extractor.finished?(item.extraction)
  end

  test "after a quota error the rest of the UTC day is used up, so other items wait without calling the API" do
    first = extracting_item(ImportSamples.certificate_text)
    second = extracting_item(ImportSamples.certificate_text(holder: "Maria Garcia"))
    Ai::FakeProvider.fail_next!

    travel_to AFTERNOON_UTC do
      Imports::AiExtractJob.perform_now(first)
      assert Ai::Budget.exhausted?

      assert_enqueued_with(job: Imports::AiExtractJob, args: [ second ], at: NEXT_RESET) do
        Imports::AiExtractJob.perform_now(second)
      end
    end

    assert_equal 1, Ai::FakeProvider.calls.size, "the second item made no call"
    assert_equal NEXT_RESET, second.reload.next_attempt_at
  end

  test "an exhausted daily budget parks the item before any call" do
    item = extracting_item(ImportSamples.certificate_text)

    travel_to AFTERNOON_UTC do
      AiUsageDay.record!(provider: "fake", units: Ai::Config.daily_budget, day: Date.new(2026, 11, 3))

      assert_enqueued_with(job: Imports::AiExtractJob, args: [ item ], at: NEXT_RESET) do
        Imports::AiExtractJob.perform_now(item)
      end
    end

    assert_empty Ai::FakeProvider.calls
    assert_equal NEXT_RESET, item.reload.next_attempt_at
  end

  test "the parked job runs after the reset and clears next_attempt_at" do
    item = extracting_item(ImportSamples.certificate_text)
    Ai::FakeProvider.fail_next!
    travel_to(AFTERNOON_UTC) { Imports::AiExtractJob.perform_now(item) }

    travel_to NEXT_RESET do
      assert_not Ai::Budget.exhausted?
      assert_enqueued_with(job: Imports::ProcessExtractionJob, args: [ item ]) do
        perform_enqueued_jobs(only: Imports::AiExtractJob)
      end
    end

    item.reload
    assert_nil item.next_attempt_at
    assert_equal "Juan A. Ortiz", item.extraction["certificates"].sole["holder_name"]
  end

  test "a file the budget stops part way keeps its finished calls and resumes after the reset without repeating them" do
    long_page = "#{ImportSamples.outline_text}\n#{"Safety briefing notes. " * 200}"
    item = extracting_item(ImportSamples.certificate_text, *Array.new(5, long_page)) # two text calls

    travel_to AFTERNOON_UTC do
      AiUsageDay.record!(provider: "fake", units: Ai::Config.daily_budget - 1, day: Date.new(2026, 11, 3))
      assert_enqueued_with(job: Imports::AiExtractJob, args: [ item ], at: NEXT_RESET) do
        Imports::AiExtractJob.perform_now(item)
      end
    end

    item.reload
    assert_equal 1, Ai::FakeProvider.calls.size, "no call once the budget ran out"
    assert Imports::Extractor.partial?(item.extraction)
    saved = Imports::Extractor.saved_calls(item.extraction).sole
    assert_equal [ 1, 2, 3, 4, 5 ], saved["pages"]
    assert_equal NEXT_RESET, item.next_attempt_at
    assert item.extracting?
    assert_no_enqueued_jobs(only: Imports::ProcessExtractionJob)

    travel_to NEXT_RESET do
      assert_enqueued_with(job: Imports::ProcessExtractionJob, args: [ item ]) do
        perform_enqueued_jobs(only: Imports::AiExtractJob)
      end
      item.reload
      assert_equal 2, Ai::FakeProvider.calls.size, "only the second call is made after the reset"
      assert_equal "This request covers page 6 only.", Ai::FakeProvider.calls.last.prompt.lines.second.strip
      assert_equal saved["units"] + Ai::Budget.used_today("fake"), item.ai_units_used
    end
    assert Imports::Extractor.finished?(item.extraction)
    assert_equal [ "Juan A. Ortiz" ], item.extraction["certificates"].map { |certificate| certificate["holder_name"] }
    assert_equal [ 2, 3, 4, 5, 6 ], item.extraction["non_certificate_pages"]
    assert_nil item.next_attempt_at
  end

  test "a file too big for a whole day's budget fails at once, before any call, and the batch finishes" do
    item = extracting_item(ImportSamples.certificate_text)

    Ai::Config.with(daily_budget: 1) do
      assert_no_enqueued_jobs(only: Imports::AiExtractJob) { Imports::AiExtractJob.perform_now(item) }
    end

    item.reload
    assert item.failed?
    assert_match "too big to read with one day's AI budget", item.error_message
    assert_match "Split it into smaller files", item.error_message
    assert_empty Ai::FakeProvider.calls
    assert @batch.reload.failed?
  end

  test "without a vision model a file with a readable certificate goes on, saying which page was not read" do
    # Page 2 has a certificate printed on it, but OCR read nothing there.
    item = extracting_item(ImportSamples.certificate_text, "", bytes: ImportSamples.pdf({}, { holder: "Li Chen" }))

    assert_enqueued_with(job: Imports::ProcessExtractionJob, args: [ item ]) do
      Ai::Config.with(extraction_vision_model: false) { Imports::AiExtractJob.perform_now(item) }
    end

    item.reload
    assert_equal [ 2 ], item.extraction["unread_pages"]
    assert_match "Page 2 was not read", item.extraction["certificates"].sole["notes"]
  end

  test "a provider without a daily allocation waits only until the error's retry time" do
    item = extracting_item(ImportSamples.certificate_text)
    retry_at = AFTERNOON_UTC + 15.minutes
    Ai::FakeProvider.fail_next!(Ai::QuotaExceeded.new("rate limited", retry_at: retry_at))

    travel_to AFTERNOON_UTC do
      assert_enqueued_with(job: Imports::AiExtractJob, args: [ item ], at: retry_at) do
        Imports::AiExtractJob.perform_now(item)
      end
    end
  end

  test "missing settings fail the item at once with what to set, and the batch finishes" do
    item = extracting_item(ImportSamples.certificate_text)

    Ai::Config.with(provider: "workers_ai") do
      assert_no_enqueued_jobs(only: Imports::AiExtractJob) { Imports::AiExtractJob.perform_now(item) }
    end

    item.reload
    assert item.failed?
    assert_match "set extraction_model", item.error_message.downcase
    assert_match "CLOUDFLARE_AI_API_TOKEN", item.error_message
    assert @batch.reload.failed?
    assert_equal 1, @batch.error_count
  end

  test "an OLLAMA_URL off this machine's network fails the item before anything is sent" do
    item = extracting_item(ImportSamples.certificate_text)
    ENV["OLLAMA_URL"] = "http://203.0.113.9:11434/v1"
    ENV["EXTRACTION_MODEL"] = "llama3.2"

    Ai::Config.with(provider: "ollama") do
      assert_no_enqueued_jobs(only: Imports::AiExtractJob) { Imports::AiExtractJob.perform_now(item) }
    end

    item.reload
    assert item.failed?
    assert_match "OLLAMA_URL points at 203.0.113.9", item.error_message
    assert_match "certificate text would leave the VM", item.error_message
    assert_empty Ai::FakeProvider.calls
    assert_nil item.extraction
  end

  test "provider errors are retried, then fail the item" do
    item = extracting_item(ImportSamples.certificate_text)
    Ai::FakeProvider.fail_next!(Ai::ProviderError.new("workers_ai request failed (ServerError): upstream 502"), times: 3)

    perform_enqueued_jobs(only: Imports::AiExtractJob) { Imports::AiExtractJob.perform_later(item) }

    item.reload
    assert item.failed?
    assert_equal "AI extraction failed after 3 attempts: workers_ai request failed (ServerError): upstream 502", item.error_message
    assert_equal 3, item.attempts
    assert_equal 3, Ai::FakeProvider.calls.size
    assert_equal 1, @batch.reload.error_count
  end

  test "an unparseable reply is retried and the next good one is stored" do
    item = extracting_item(ImportSamples.certificate_text)
    Ai::FakeProvider.reply_next!("I could not find any certificates, sorry!")

    perform_enqueued_jobs(only: Imports::AiExtractJob) { Imports::AiExtractJob.perform_later(item) }

    item.reload
    assert_equal 2, item.attempts
    assert_equal 1, item.extraction["certificates"].size
    assert_equal 2, AiUsageDay.find_by!(provider: "fake").requests, "the failed reply was counted too"
  end

  test "an unexpected error fails the item and is re-raised for the jobs dashboard" do
    item = extracting_item(ImportSamples.certificate_text)
    Ai::FakeProvider.fail_next!(NoMethodError.new("undefined method 'oops'"))

    assert_raises(NoMethodError) { Imports::AiExtractJob.perform_now(item) }

    item.reload
    assert item.failed?
    assert_match "AI extraction failed unexpectedly (NoMethodError)", item.error_message
  end

  test "a page image that cannot be rendered fails the item without retrying" do
    item = extracting_item("")
    item.file.attach(io: StringIO.new("not a pdf"), filename: "broken.pdf", content_type: "application/pdf")

    assert_no_enqueued_jobs(only: Imports::AiExtractJob) { Imports::AiExtractJob.perform_now(item) }

    item.reload
    assert item.failed?
    assert_match "The page image for the vision model could not be made", item.error_message
  end

  test "items that left the pipeline are not touched" do
    item = extracting_item(ImportSamples.certificate_text)
    item.update!(status: :rejected, rejection_reason: "Rejected while waiting")

    assert_no_enqueued_jobs { Imports::AiExtractJob.perform_now(item) }
    assert_empty Ai::FakeProvider.calls
    assert_nil item.reload.extraction
  end

  test "a repeat run of an extracted item goes straight to step 5 without calling the AI" do
    item = extracting_item(ImportSamples.certificate_text)
    item.update!(extraction: { "certificates" => [], "non_certificate_pages" => [ 1 ] })

    assert_enqueued_with(job: Imports::ProcessExtractionJob, args: [ item ]) do
      Imports::AiExtractJob.perform_now(item)
    end
    assert_empty Ai::FakeProvider.calls
  end

  test "a deleted item discards the job" do
    item = extracting_item(ImportSamples.certificate_text)
    Imports::AiExtractJob.perform_later(item)
    item.destroy!

    assert_nothing_raised { perform_enqueued_jobs(only: Imports::AiExtractJob) }
  end

  private
    # bytes: the file, when it should differ from a text PDF of the pages (OCR missed something).
    def extracting_item(*pages, bytes: ImportSamples.pdf(*pages))
      text = pages.each_with_index.map { |page, index| "=== page #{index + 1} ===\n#{page}" }.join("\n\n")
      item = @batch.import_items.create!(original_filename: "scan-#{SecureRandom.hex(3)}.pdf",
        sha256: Digest::SHA256.hexdigest(bytes + SecureRandom.hex(4)), status: :extracting, extracted_text: text)
      item.file.attach(io: StringIO.new(bytes), filename: item.original_filename, content_type: "application/pdf")
      item
    end
end
