require "vips"

module Imports
  # Step 4 of the import pipeline: turns one source file's OCR text into the model output
  # contract with the configured AI model (docs/PLAN.md, "Bulk import pipeline").
  #
  #   result = Imports::Extractor.new(item).call
  #   result.data     # => { "certificates" => [...], "non_certificate_pages" => [...] }, normalized
  #   result.provider # => "workers_ai"
  #   result.units    # => neurons (or tokens) used, already recorded by Ai::Client
  #
  #   # Resuming a file that was stopped part way (Imports::AiExtractJob does this):
  #   Imports::Extractor.new(item, done: Imports::Extractor.saved_calls(item.extraction)).call do |calls|
  #     item.update!(extraction: Imports::Extractor.partial_extraction(calls))
  #   end
  #
  #   # The accuracy harness, without an ImportItem:
  #   Imports::Extractor.for_file("/path/card.pdf", content_type: "application/pdf", text: ocr_text).call
  #
  # Pages whose text is usable (Imports::TextExtractor.usable?) go to EXTRACTION_MODEL, in one call
  # unless the file is over MAX_DOCUMENT_CHARS (then several, never splitting a page). With a vision
  # model set, a scanned page or photo goes to it instead, whatever OCR made of it: the accuracy
  # test (Nov 5, 2026) found OCR garbles a photo's text in ways that still look usable ("Rash
  # Williams"), where the vision model reads the image correctly. It doesn't get the OCR text either:
  # withholding it scored better on every field.
  # Pages OCR could not read are rendered (Imports::PageImages): a blank one (blank_page?) is a
  # non-certificate page with no AI call, and the rest go to EXTRACTION_VISION_MODEL with their
  # image, as many per call as the model accepts (config/ai_models.yml max_images). With no
  # vision model set they are skipped: data["unread_pages"] lists them and every certificate's
  # notes say so. Each call's reply is checked against the pages it covered, then merged.
  #
  # The daily budget (docs/PLAN.md, "Staying inside the free allocation"):
  #   - before the first call, the whole file's cost is estimated (estimated_units); a file
  #     estimated over Ai::Config.daily_budget raises OverBudget, as it would use up more than a
  #     day's free allocation;
  #   - Ai::Client checks today's usage before every call and raises Ai::QuotaExceeded once it
  #     is used up;
  #   - the block, when given, receives every finished call (saved_calls format) after each new
  #     one, so a file stopped part way resumes with done: instead of paying for those calls again.
  #
  # Raises Ai::ConfigurationError (no model, no keys, nothing readable and no vision model),
  # OverBudget, and Ai::QuotaExceeded, Ai::ProviderError and Ai::ResponseError from Ai::Client.
  class Extractor
    Result = Data.define(:data, :provider, :model, :units, :input_tokens, :output_tokens, :images, :requests) do
      def ai_units_used = units
    end

    # The file needs more AI time than one day's budget allows. estimate is in neurons.
    class OverBudget < StandardError
      attr_reader :estimate, :budget

      def initialize(message = nil, estimate: nil, budget: nil)
        @estimate = estimate
        @budget = budget
        super(message || "estimated #{estimate} units, over the daily budget of #{budget}")
      end
    end

    # One AI call the file needs. image_pages are the page numbers whose images it carries.
    PlannedCall = Data.define(:model, :pages, :image_pages, :system, :user, :max_output_tokens) do
      # What a saved call must match to be reused: same model, same pages, same text sent.
      def key = { "model" => model, "pages" => pages, "digest" => Digest::SHA256.hexdigest(user) }
    end
    private_constant :PlannedCall

    MAX_DOCUMENT_CHARS = 24_000 # per call: about 6,000 tokens, inside every candidate's context window
    MAX_LONG_SIDE = 1568
    TEXT_OUTPUT_TOKENS = 2048
    VISION_OUTPUT_TOKENS = 2048 # a page photographed with nine cards on it needs more than 1024
    # The reply size assumed by estimated_units: about one certificate entry per page.
    ESTIMATED_OUTPUT_TOKENS_PER_CALL = 50
    ESTIMATED_OUTPUT_TOKENS_PER_PAGE = 150
    # A rendered page is blank when fewer than BLANK_INK_SHARE of its pixels differ from the
    # page's median brightness by more than BLANK_CONTRAST (of 255). Paper grain and faint
    # bleed-through stay under the contrast; a page with a few lines of text is over 0.1% ink.
    BLANK_CONTRAST = 48
    BLANK_INK_SHARE = 0.0005
    PARTIAL_KEY = "partial".freeze
    KEY_FIELDS = %w[model pages digest].freeze

    # slice_before predicate: starts a new chunk when the next page would push it over the limit.
    class ChunkBoundary
      def initialize(limit)
        @limit = limit
        @size = 0
      end

      def ===(page)
        length = [ page.last.to_s.length, Extraction::Prompt::PAGE_CHAR_LIMIT ].min + 80 # marker and cut note
        start = @size.positive? && @size + length > @limit
        @size = start ? length : @size + length
        start
      end
    end
    private_constant :ChunkBoundary

    class << self
      def for_file(path, content_type:, text:, scanned_pages: nil)
        new(nil, text: text, file_path: path, content_type: content_type, scanned_pages: scanned_pages)
      end

      # [[page number, text], ...] from extracted_text ("=== page N ===" markers, see
      # Imports::TextExtractor.split_pages). No text at all is one empty page: an image or scan
      # OCR found nothing on, which goes to the vision model.
      def parse_pages(text)
        pages = Imports::TextExtractor.split_pages(text.to_s).map { |page| [ page.number, page.text.to_s ] }
        pages = [ [ 1, "" ] ] if pages.empty?
        pages.uniq(&:first).sort_by(&:first)
      end

      # True when the page image at path has (next to) no marks on it. An image that can't be
      # read is not blank.
      def blank_page?(path)
        image = Vips::Image.new_from_file(path.to_s)
        image = image.flatten(background: 255) if image.has_alpha?
        gray = image.colourspace(:b_w)[0]
        ink = (gray - gray.percent(50)).abs > BLANK_CONTRAST
        ink.avg / 255.0 < BLANK_INK_SHARE
      rescue Vips::Error
        false
      end

      # The stored form of a file stopped part way: item.extraction holds it until the file is done.
      def partial_extraction(calls)
        { PARTIAL_KEY => { "calls" => Array(calls) } }
      end

      def partial?(extraction)
        extraction.is_a?(Hash) && extraction.key?(PARTIAL_KEY)
      end

      # True when extraction is a finished result (not empty, not partial).
      def finished?(extraction)
        extraction.present? && !partial?(extraction)
      end

      # The calls saved by partial_extraction, or [] for anything else.
      def saved_calls(extraction)
        return [] unless partial?(extraction)

        Array(extraction.dig(PARTIAL_KEY, "calls")).select { |call| call.is_a?(Hash) && KEY_FIELDS.all? { |key| call.key?(key) } }
      end
    end

    # done: calls saved from an earlier run of the same file (saved_calls), reused when they match.
    # scanned_pages: the page numbers whose text came from OCR.
    def initialize(item = nil, text: nil, file_path: nil, content_type: nil, scanned_pages: nil, done: [])
      @item = item
      @text = text || item&.extracted_text
      @file_path = file_path
      @content_type = content_type || (item&.file&.content_type if item&.file&.attached?)
      @scanned_pages = scanned_pages || item&.ocr_pages || []
      @done = Array(done).map(&:stringify_keys)
    end

    # Yields every finished call so far after each new one (see the class comment).
    def call(&on_progress)
      provider = Ai::Config.provider
      Ai::Config.ensure_ready!(provider)

      pages = self.class.parse_pages(@text)
      vision_model = Ai::Config.extraction_vision_model(provider)
      usable, unreadable = pages.partition do |number, text|
        Imports::TextExtractor.usable?(text) && !(vision_model && scanned?(number))
      end
      vision_model = nil if unreadable.empty?

      with_page_images(unreadable.map(&:first), vision: vision_model.present?) do |images, blank|
        unread = vision_model ? [] : images.keys
        raise Ai::ConfigurationError, unread_message(unread) if unread.any? && usable.empty?

        page_texts = pages.to_h
        planned = text_calls(provider, usable, pages.size)
        planned.concat(vision_calls(vision_model, images.keys.map { |number| [ number, (page_texts[number] unless withhold_ocr_text?(provider, number)) ] }, pages.size)) if vision_model
        calls = perform(provider, planned, images, &on_progress)
        merge(provider, calls, blank: blank, unread: unread)
      end
    end

    private
      # The fake provider has no eyes, so it still reads the text.
      def withhold_ocr_text?(provider, number)
        provider.to_s != "fake" && scanned?(number)
      end

      def scanned?(number)
        @content_type.to_s.start_with?("image/") || @scanned_pages.include?(number)
      end

      def text_calls(provider, usable, page_count)
        model = Ai::Config.extraction_model(provider)
        text_chunks(usable).map do |chunk|
          prompt = Extraction::Prompt.new(certificate_types: certificate_types, pages: chunk, page_count: page_count)
          PlannedCall.new(model: model, pages: chunk.map(&:first), image_pages: [], system: prompt.system, user: prompt.user,
            max_output_tokens: TEXT_OUTPUT_TOKENS)
        end
      end

      def vision_calls(model, pages, page_count)
        pages.each_slice(Ai::Config.max_images(model)).map do |chunk|
          numbers = chunk.map(&:first)
          prompt = Extraction::Prompt.new(certificate_types: certificate_types, pages: chunk, page_count: page_count, image_pages: numbers)
          PlannedCall.new(model: model, pages: numbers, image_pages: numbers, system: prompt.system, user: prompt.user,
            max_output_tokens: VISION_OUTPUT_TOKENS)
        end
      end

      # Groups pages so no call carries more than MAX_DOCUMENT_CHARS of text (a page is never split).
      def text_chunks(pages)
        pages.slice_before(ChunkBoundary.new(MAX_DOCUMENT_CHARS)).to_a
      end

      # Makes the planned calls not already done, in order, and returns every call's record.
      def perform(provider, planned, images, &on_progress)
        finished = @done.index_by { |call| call.slice(*KEY_FIELDS) }
        pending = planned.reject { |planned_call| finished.key?(planned_call.key) }
        ensure_affordable!(provider, pending)

        pending.each do |planned_call|
          finished[planned_call.key] = request(provider, planned_call, images)
          on_progress&.call(planned.filter_map { |each_call| finished[each_call.key] })
        end
        planned.map { |planned_call| finished.fetch(planned_call.key) }
      end

      def request(provider, planned_call, images)
        response = Ai::Client.new(provider: provider, model: planned_call.model).json(system: planned_call.system,
          prompt: planned_call.user, schema: Extraction::Schema::JSON_SCHEMA,
          images: planned_call.image_pages.map { |number| images.fetch(number) }, max_output_tokens: planned_call.max_output_tokens)
        planned_call.key.merge("data" => response.data, "units" => response.units, "input_tokens" => response.input_tokens,
          "output_tokens" => response.output_tokens, "images" => response.images)
      end

      # Refuses, before the first call, a file that would need more than a day's budget.
      def ensure_affordable!(provider, pending)
        return unless Ai::Budget.limited?(provider) && pending.any?

        estimate = pending.sum { |planned_call| estimated_units(provider, planned_call) }
        budget = Ai::Config.daily_budget(provider)
        return if estimate <= budget

        unit, setting = Ai::Config.paid_ceiling?(provider) ? %w[tokens AI_DAILY_TOKEN_BUDGET] : %w[neurons AI_DAILY_NEURON_BUDGET]
        raise OverBudget.new("This file is too big to read with one day's AI budget: it needs about " \
          "#{estimate.to_fs(:delimited)} #{unit} over #{pending.size} AI calls, and the daily budget " \
          "(#{setting}) is #{budget.to_fs(:delimited)}. Split it into smaller files and upload those.",
          estimate: estimate, budget: budget)
      end

      def estimated_units(provider, planned_call)
        output = ESTIMATED_OUTPUT_TOKENS_PER_CALL + ESTIMATED_OUTPUT_TOKENS_PER_PAGE * planned_call.pages.size
        Ai::Budget.units_for(provider: provider, model: planned_call.model,
          input_tokens: ((planned_call.system.length + planned_call.user.length) / 4.0).ceil,
          output_tokens: [ output, planned_call.max_output_tokens ].min, images: planned_call.image_pages.size)
      end

      def merge(provider, calls, blank:, unread:)
        certificates = []
        non_certificate_pages = blank.dup
        calls.each do |call|
          data = Extraction::Normalizer.new(pages: call["pages"], codes: certificate_types.map(&:first)).call(call["data"])
          certificates.concat(data["certificates"])
          non_certificate_pages.concat(data["non_certificate_pages"])
        end
        certificates.sort_by! { |certificate| certificate["pages"].first.to_i }
        claimed = certificates.flat_map { |certificate| certificate["pages"] }
        data = { "certificates" => certificates, "non_certificate_pages" => (non_certificate_pages.uniq - claimed).sort }
        note_unread(data, unread) if unread.any?

        Result.new(
          data: data,
          provider: provider,
          model: calls.map { |call| call["model"] }.uniq.join(", ").presence,
          units: calls.sum { |call| call["units"].to_i },
          input_tokens: calls.sum { |call| call["input_tokens"].to_i },
          output_tokens: calls.sum { |call| call["output_tokens"].to_i },
          images: calls.sum { |call| call["images"].to_i },
          requests: calls.size
        )
      end

      # No vision model: the readable pages' certificates go on, saying which pages were not read.
      # With none found, the unread pages may hold one, so the file fails instead of being rejected.
      def note_unread(data, unread)
        if data["certificates"].empty?
          raise Ai::ConfigurationError, "#{unread_message(unread)} No certificate was found on the pages it could read."
        end

        note = "#{unread.size == 1 ? "Page" : "Pages"} #{unread.to_sentence} #{unread.size == 1 ? "was" : "were"} not read: " \
          "OCR could not read #{unread.size == 1 ? "it" : "them"} and no vision model is set (EXTRACTION_VISION_MODEL)."
        data["certificates"].each { |certificate| certificate["notes"] = [ certificate["notes"], note ].compact.join(" ") }
        data["unread_pages"] = unread
      end

      def unread_message(numbers)
        "OCR could not read #{numbers.size == 1 ? "page" : "pages"} #{numbers.to_sentence}, " \
          "and no vision model is set: set EXTRACTION_VISION_MODEL (#{Ai::Config::SPIKE_DOC})."
      end

      # Active certificate types as [[code, name, aliases], ...].
      def certificate_types
        @certificate_types ||= CertificateType.active.ordered.pluck(:code, :name, :aliases)
      end

      # Renders the unreadable pages and yields ({ number => jpeg path } for those that aren't
      # blank, [blank page numbers]). The JPEGs are deleted when the block returns. Without a
      # vision model a page that can't be rendered is just unread, not an error.
      def with_page_images(numbers, vision:, &block)
        return yield({}, []) if numbers.empty?

        with_file_path { |path| render_pages(path, numbers, {}, [], vision, &block) }
      end

      def render_pages(path, numbers, images, blank, vision, &block)
        return yield(images, blank) if numbers.empty?

        number, *rest = numbers
        rendered = false
        Imports::PageImages.render(path, content_type: @content_type, page: number, max_long_side: MAX_LONG_SIDE) do |jpeg|
          rendered = true
          if self.class.blank_page?(jpeg)
            render_pages(path, rest, images, blank + [ number ], vision, &block)
          else
            render_pages(path, rest, images.merge(number => jpeg), blank, vision, &block)
          end
        end
      rescue Imports::TextExtractor::Error, Imports::Shell::Error
        raise if rendered || vision # an error from a later page or the calls, or one the vision model needed

        render_pages(path, rest, images.merge(number => nil), blank, vision, &block)
      end

      def with_file_path
        return yield(@file_path) if @file_path
        raise ArgumentError, "import item #{@item&.id.inspect} has no file to render page images from" unless @item&.file&.attached?

        @item.file.open { |file| yield(file.path) }
      end
  end
end
