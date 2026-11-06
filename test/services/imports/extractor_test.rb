require "test_helper"
require "support/import_samples"

class Imports::ExtractorTest < ActiveSupport::TestCase
  ENV_KEYS = %w[EXTRACTION_MODEL EXTRACTION_VISION_MODEL].freeze

  setup do
    AiUsageDay.delete_all
    @saved_env = ENV_KEYS.index_with { |name| ENV[name] }
    ENV_KEYS.each { |name| ENV.delete(name) }
  end

  teardown do
    @saved_env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    Ai::FakeProvider.reset!
    @restore_page_images&.call
  end

  test "one call per file returns every certificate with its pages, and the non-certificate pages" do
    item = item_for(ImportSamples.pdf({}, :outline, { holder: "Li Chen", name: "Flagger Certification", expires: "2028-03-14" }),
      text: page_text(ImportSamples.certificate_text, ImportSamples.outline_text,
        ImportSamples.certificate_text(holder: "Li Chen", name: "Flagger Certification", expires: "2028-03-14")))

    result = Imports::Extractor.new(item).call

    assert_equal 1, result.requests
    call = Ai::FakeProvider.calls.sole
    assert_equal "fake-extractor", call.model
    assert_empty call.images
    assert_equal [ [ 1 ], [ 3 ] ], result.data["certificates"].map { |certificate| certificate["pages"] }
    assert_equal [ "OSHA30", "FLAGGER" ], result.data["certificates"].map { |certificate| certificate["certificate_type_code"] }
    assert_equal "Li Chen", result.data["certificates"].last["holder_name"]
    assert_equal [ 2 ], result.data["non_certificate_pages"]
    assert_equal "fake", result.provider
    assert_equal "fake-extractor", result.model
    assert_operator result.units, :>, 0
    assert_equal result.units, result.ai_units_used
    assert_equal result.units, Ai::Budget.used_today("fake")
  end

  test "the prompt lists active master-list types only, so inactive codes never come back" do
    item = item_for(ImportSamples.pdf({ name: "HAZWOPER 40 Hour" }), text: page_text(ImportSamples.certificate_text(name: "HAZWOPER 40 Hour")))

    result = Imports::Extractor.new(item).call

    system = Ai::FakeProvider.calls.sole.system
    assert_includes system, %("code":"OSHA30")
    assert_not_includes system, "HAZWOPER40"
    assert_nil result.data["certificates"].sole["certificate_type_code"]
  end

  test "the reply is normalized against the certificate types and the file's pages" do
    Ai::FakeProvider.reply_next!({ "certificates" => [ { "pages" => [ 1, 7 ], "holder_name" => "Juan Ortiz",
      "certificate_type_code" => "osha30", "completed_on" => "14/03/2025", "confidence" => 3 },
      { "pages" => [ 2 ], "certificate_type_code" => "NOPE", "holder_name" => "Li Chen", "confidence" => 0.9 } ] })
    item = item_for(ImportSamples.pdf({}, {}), text: page_text(ImportSamples.certificate_text, ImportSamples.certificate_text))

    certificates = Imports::Extractor.new(item).call.data["certificates"]

    assert_equal [ [ 1 ], [ 2 ] ], certificates.map { |certificate| certificate["pages"] }
    assert_equal [ "OSHA30", nil ], certificates.map { |certificate| certificate["certificate_type_code"] }
    assert_nil certificates.first["completed_on"]
    assert_equal [ 0.03, 0.9 ], certificates.map { |certificate| certificate["confidence"] }
  end

  test "with a vision model, a photo goes to it even when OCR found plausible text; a page with a text layer stays on the text model" do
    photo = Imports::Extractor.for_file(file_fixture("certificate.jpg").to_s, content_type: "image/jpeg",
      text: "=== page 1 ===\nCertificate of Completion Rash Williams Flagger completed 2025-03-14 and more words to read")
    photo.call
    assert_equal [ "fake-vision" ], Ai::FakeProvider.calls.map(&:model)
    Ai::FakeProvider.reset!

    Ai::Config.with(extraction_vision_model: false) do
      Imports::Extractor.for_file(file_fixture("certificate.jpg").to_s, content_type: "image/jpeg",
        text: "=== page 1 ===\nCertificate of Completion Rash Williams Flagger completed 2025-03-14 and more words to read").call
    end
    assert_equal [ "fake-extractor" ], Ai::FakeProvider.calls.map(&:model), "no vision model: OCR's reading is all there is"
  end

  test "the vision model isn't given a scanned page's OCR text, except by the fake provider, which has no eyes" do
    extractor = Imports::Extractor.for_file(file_fixture("certificate.jpg").to_s, content_type: "image/jpeg", text: "x")
    text_pdf = Imports::Extractor.for_file(file_fixture("certificate.jpg").to_s, content_type: "application/pdf", text: "x", scanned_pages: [ 2 ])

    assert extractor.send(:withhold_ocr_text?, "workers_ai", 1)
    assert_not extractor.send(:withhold_ocr_text?, "fake", 1)
    assert text_pdf.send(:withhold_ocr_text?, "workers_ai", 2)
    assert_not text_pdf.send(:withhold_ocr_text?, "workers_ai", 1), "a text layer page isn't scanned"
  end

  test "a page OCR could not read goes to the vision model with its page image" do
    Ai::FakeProvider.reply_next!({ "certificates" => [ { "pages" => [ 1 ], "holder_name" => "Juan A. Ortiz",
      "certificate_type_code" => "OSHA30", "completed_on" => "2025-03-14", "confidence" => 0.9 } ], "non_certificate_pages" => [] })
    item = item_for(ImportSamples.image({ holder: "Juan A. Ortiz" }, format: :jpeg), filename: "card.jpg", content_type: "image/jpeg",
      text: page_text(""))
    seen = []
    track_images(seen)

    result = Imports::Extractor.new(item).call

    call = Ai::FakeProvider.calls.sole
    assert_equal "fake-vision", call.model
    assert_equal 1, call.images.size
    assert_equal [ true ], seen.map { |path| path.end_with?(".jpg") }
    assert_not File.exist?(call.images.first), "page images are deleted after the call"
    assert_match "OCR could not read page 1", call.prompt
    assert_equal "Juan A. Ortiz", result.data["certificates"].sole["holder_name"]
    assert_equal 1, result.images
  end

  test "readable pages go in the text call and unreadable ones to the vision model, as many per call as it takes" do
    pdf = ImportSamples.pdf({}, {}, {}, {})
    item = item_for(pdf, text: page_text(ImportSamples.certificate_text, "", "  ", "~~ ~~"))

    result = Imports::Extractor.new(item).call

    calls = Ai::FakeProvider.calls
    assert_equal [ "fake-extractor", "fake-vision", "fake-vision" ], calls.map(&:model)
    assert_equal [ 0, 2, 1 ], calls.map { |call| call.images.size } # fake-vision takes 2 images per call
    assert_match "This request covers pages 2 and 3 only.", calls.second.prompt
    assert_equal 3, result.requests
    assert_equal 3, result.images
    assert_equal "fake-extractor, fake-vision", result.model
    assert_equal [ [ 1 ] ], result.data["certificates"].map { |certificate| certificate["pages"] }
    assert_equal [ 2, 3, 4 ], result.data["non_certificate_pages"]
  end

  test "a long file is split into several text calls without splitting a page" do
    long_page = "#{ImportSamples.outline_text}\n#{"Safety briefing notes. " * 200}" # ~4,900 characters
    item = item_for(ImportSamples.pdf({}), text: page_text(*Array.new(6, long_page)))

    result = Imports::Extractor.new(item).call

    assert_equal 2, result.requests
    intros = Ai::FakeProvider.calls.map { |call| call.prompt.lines.second.strip }
    assert_equal [ "This request covers pages 1, 2, 3, and 4 only.", "This request covers pages 5 and 6 only." ], intros
    assert_equal [ 1, 2, 3, 4, 5, 6 ], result.data["non_certificate_pages"]
  end

  test "for_file extracts from a path without an import item" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "card.pdf")
      File.binwrite(path, ImportSamples.pdf({ holder: "Maria Garcia" }))

      result = Imports::Extractor.for_file(path, content_type: "application/pdf",
        text: page_text(ImportSamples.certificate_text(holder: "Maria Garcia"))).call

      assert_equal "Maria Garcia", result.data["certificates"].sole["holder_name"]
    end
  end

  test "quota errors from the provider propagate" do
    Ai::FakeProvider.fail_next!
    item = item_for(ImportSamples.pdf({}), text: page_text(ImportSamples.certificate_text))

    assert_raises(Ai::QuotaExceeded) { Imports::Extractor.new(item).call }
  end

  test "fails fast when the provider is not configured" do
    item = item_for(ImportSamples.pdf({}), text: page_text(ImportSamples.certificate_text))

    Ai::Config.with(provider: "workers_ai") do
      error = assert_raises(Ai::ConfigurationError) { Imports::Extractor.new(item).call }
      assert_match "EXTRACTION_MODEL", error.message
    end
    assert_empty Ai::FakeProvider.calls
  end

  test "an unreadable page without a vision model is a configuration error, before any call" do
    ENV["EXTRACTION_MODEL"] = "llama3.2"
    item = item_for(ImportSamples.pdf({}), text: page_text(""))

    Ai::Config.with(provider: "ollama") do
      error = assert_raises(Ai::ConfigurationError) { Imports::Extractor.new(item).call }
      assert_match "OCR could not read page 1", error.message
      assert_match "EXTRACTION_VISION_MODEL", error.message
    end
  end

  # --- blank pages and no vision model ---------------------------------------------

  test "a blank page is a non-certificate page with no AI call" do
    item = item_for(ImportSamples.pdf({}, ""), text: page_text(ImportSamples.certificate_text, ""))

    result = Imports::Extractor.new(item).call

    assert_equal [ "fake-extractor" ], Ai::FakeProvider.calls.map(&:model), "no vision call for the blank back page"
    assert_equal [ [ 1 ] ], result.data["certificates"].map { |certificate| certificate["pages"] }
    assert_equal [ 2 ], result.data["non_certificate_pages"]
    assert_equal 0, result.images
  end

  test "a file of blank pages makes no call at all" do
    item = item_for(ImportSamples.pdf("", ""), text: page_text("", ""))

    result = Imports::Extractor.new(item).call

    assert_empty Ai::FakeProvider.calls
    assert_equal({ "certificates" => [], "non_certificate_pages" => [ 1, 2 ] }, result.data)
    assert_equal [ 0, 0, nil ], [ result.requests, result.units, result.model ]
  end

  test "blank_page? tells an empty page from one with a few lines on it" do
    Dir.mktmpdir do |dir|
      blank = File.join(dir, "blank.jpg")
      Vips::Image.black(600, 800).invert.jpegsave(blank)
      card = File.join(dir, "card.jpg")
      File.binwrite(card, ImportSamples.image({}))
      short = File.join(dir, "short.jpg")
      File.binwrite(short, ImportSamples.image("Juan A. Ortiz\nOSHA 30\n2025-03-14"))

      assert Imports::Extractor.blank_page?(blank)
      assert_not Imports::Extractor.blank_page?(card)
      assert_not Imports::Extractor.blank_page?(short)
      assert_not Imports::Extractor.blank_page?(File.join(dir, "missing.jpg")), "an unreadable image is not blank"
    end
  end

  test "without a vision model the readable pages are still read and the unread ones are named" do
    item = item_for(ImportSamples.pdf({}, { holder: "Li Chen" }, ""), text: page_text(ImportSamples.certificate_text, "~~ ~~", ""))

    result = Ai::Config.with(extraction_vision_model: false) { Imports::Extractor.new(item).call }

    assert_equal [ "fake-extractor" ], Ai::FakeProvider.calls.map(&:model)
    certificate = result.data["certificates"].sole
    assert_equal [ 1 ], certificate["pages"]
    assert_match "Page 2 was not read: OCR could not read it and no vision model is set (EXTRACTION_VISION_MODEL).", certificate["notes"]
    assert_equal [ 2 ], result.data["unread_pages"]
    assert_equal [ 3 ], result.data["non_certificate_pages"], "the blank page needs no model"
  end

  test "without a vision model, unread pages and no certificate elsewhere fail the file rather than reject it" do
    item = item_for(ImportSamples.pdf(:outline, {}), text: page_text(ImportSamples.outline_text, ""))

    error = Ai::Config.with(extraction_vision_model: false) do
      assert_raises(Ai::ConfigurationError) { Imports::Extractor.new(item).call }
    end
    assert_match "OCR could not read page 2, and no vision model is set: set EXTRACTION_VISION_MODEL", error.message
    assert_match "No certificate was found on the pages it could read.", error.message
  end

  # --- the daily budget ------------------------------------------------------------------

  test "the budget is checked before every call: a long file stops when it runs out, keeping the finished calls" do
    item = item_for(ImportSamples.pdf({}), text: long_text)
    AiUsageDay.record!(provider: "fake", units: Ai::Config.daily_budget - 1, day: Time.current.utc.to_date)
    saved = []

    assert_raises(Ai::QuotaExceeded) { Imports::Extractor.new(item).call { |calls| saved << calls } }

    assert_equal 1, Ai::FakeProvider.calls.size, "the second call was not sent"
    assert_equal 1, saved.size
    call = saved.sole.sole
    assert_equal [ 1, 2, 3, 4 ], call["pages"]
    assert_equal "fake-extractor", call["model"]
    assert_operator call["units"], :>, 0
    assert_equal [ 1, 2, 3, 4 ], call.dig("data", "non_certificate_pages")
  end

  test "a resumed file reuses its finished calls and only makes the rest" do
    item = item_for(ImportSamples.pdf({}), text: long_text)
    first_run = []
    AiUsageDay.record!(provider: "fake", units: Ai::Config.daily_budget - 1, day: Time.current.utc.to_date)
    assert_raises(Ai::QuotaExceeded) { Imports::Extractor.new(item).call { |calls| first_run = calls } }
    AiUsageDay.delete_all
    Ai::FakeProvider.reset!
    stored = Imports::Extractor.partial_extraction(first_run).as_json # as it comes back from jsonb

    progress = []
    result = Imports::Extractor.new(item, done: Imports::Extractor.saved_calls(stored)).call { |calls| progress << calls.size }

    assert_equal [ "This request covers pages 5 and 6 only." ], Ai::FakeProvider.calls.map { |call| call.prompt.lines.second.strip }
    assert_equal [ 2 ], progress
    assert_equal 2, result.requests
    assert_equal [ 1, 2, 3, 4, 5, 6 ], result.data["non_certificate_pages"]
    assert_equal first_run.sole["units"] + Ai::Budget.used_today("fake"), result.units, "the item's cost includes the earlier day"
  end

  test "saved calls for other text or another model are not reused" do
    item = item_for(ImportSamples.pdf({}), text: page_text(ImportSamples.certificate_text))
    stale = [
      { "model" => "fake-extractor", "pages" => [ 1 ], "digest" => "0" * 64, "data" => { "certificates" => [] }, "units" => 5 },
      { "model" => "an-old-model", "pages" => [ 1 ], "digest" => "x", "data" => {}, "units" => 5 }
    ]

    result = Imports::Extractor.new(item, done: stale).call

    assert_equal 1, Ai::FakeProvider.calls.size
    assert_equal "Juan A. Ortiz", result.data["certificates"].sole["holder_name"]
    assert_equal Ai::Budget.used_today("fake"), result.units
  end

  test "a file estimated over a whole day's budget fails before any call, with what to do" do
    item = item_for(ImportSamples.pdf({}), text: long_text)

    error = Ai::Config.with(daily_budget: 20) do
      assert_raises(Imports::Extractor::OverBudget) { Imports::Extractor.new(item).call }
    end

    assert_empty Ai::FakeProvider.calls
    assert_equal 20, error.budget
    assert_operator error.estimate, :>, 20
    assert_match(/needs about \d+ neurons over 2 AI calls, and the daily budget \(AI_DAILY_NEURON_BUDGET\) is 20/, error.message)
    assert_match "Split it into smaller files", error.message
  end

  test "the estimate counts each page image at the vision model's rate" do
    pdf = ImportSamples.pdf({}, {}, {}, {})
    item = item_for(pdf, text: page_text(*Array.new(4, "")))
    per_image = Ai::Config.model_settings("fake-vision")[:per_image]

    error = Ai::Config.with(daily_budget: per_image * 4 - 1) do
      assert_raises(Imports::Extractor::OverBudget) { Imports::Extractor.new(item).call }
    end
    assert_operator error.estimate, :>=, per_image * 4
    assert_empty Ai::FakeProvider.calls
  end

  test "partial extraction helpers" do
    calls = [ { "model" => "m", "pages" => [ 1 ], "digest" => "d", "data" => {} } ]
    partial = Imports::Extractor.partial_extraction(calls)

    assert Imports::Extractor.partial?(partial)
    assert_not Imports::Extractor.finished?(partial)
    assert Imports::Extractor.finished?({ "certificates" => [], "non_certificate_pages" => [ 1 ] })
    assert_not Imports::Extractor.finished?(nil)
    assert_equal calls, Imports::Extractor.saved_calls(partial.as_json)
    assert_empty Imports::Extractor.saved_calls({ "certificates" => [] })
    assert_empty Imports::Extractor.saved_calls({ "partial" => { "calls" => [ "junk", { "model" => "m" } ] } })
  end

  test "parse_pages reads the stored page markers, and no text is one empty page" do
    assert_equal [ [ 1, "a" ], [ 2, "" ], [ 3, "c" ] ], Imports::Extractor.parse_pages("=== page 1 ===\na\n\n=== page 2 ===\n\n=== page 3 ===\nc")
    assert_equal [ [ 1, "plain text" ] ], Imports::Extractor.parse_pages("plain text")
    assert_equal [ [ 1, "" ] ], Imports::Extractor.parse_pages(nil)
  end

  private
    # Six ~4,900-character pages: two text calls (pages 1-4, then 5-6).
    def long_text
      page_text(*Array.new(6, "#{ImportSamples.outline_text}\n#{"Safety briefing notes. " * 200}"))
    end

    def page_text(*pages)
      pages.each_with_index.map { |text, index| "=== page #{index + 1} ===\n#{text}" }.join("\n\n")
    end

    def item_for(bytes, text:, filename: "scan.pdf", content_type: "application/pdf")
      item = ImportItem.create!(import_batch: import_batches(:march_batch), original_filename: filename,
        sha256: Digest::SHA256.hexdigest(bytes), status: :extracting, extracted_text: text)
      item.file.attach(io: StringIO.new(bytes), filename: filename, content_type: content_type)
      item
    end

    # Records the page image paths while they still exist (they are deleted after each call).
    def track_images(seen)
      original = Imports::PageImages.method(:render)
      Imports::PageImages.define_singleton_method(:render) do |*args, **options, &block|
        original.call(*args, **options) do |path|
          seen << path if File.exist?(path)
          block.call(path)
        end
      end
      @restore_page_images = -> { Imports::PageImages.singleton_class.remove_method(:render) }
    end
end
