module Imports
  module Eval
    # The Phase 3 accuracy harness behind bin/rails "certtrack:eval_extraction[provider,model]":
    # runs local text extraction and Imports::Extractor on every sample with the given provider
    # and models, and scores each against its expected JSON. Nothing is written to import tables;
    # the AI usage is recorded in ai_usage_days like any other call (it spends the same allocation).
    #
    #   report = Imports::Eval::Runner.new(dir: "test/fixtures/import_samples", provider: "workers_ai",
    #     model: "@cf/meta/llama-3.3-70b-instruct-fp8-fast", vision_model: "@cf/meta/llama-4-scout-17b-16e-instruct").call
    #   puts report.to_s
    #
    # Raises NoSamples when the directory has no scorable sample, and Ai::ConfigurationError when
    # the provider is not set up. A quota error stops the run and keeps the rows done so far.
    class Runner
      class NoSamples < StandardError; end

      Row = Data.define(:sample, :score, :units, :input_tokens, :output_tokens, :requests, :seconds, :error, :quota)

      # vision_only: true drops the OCR text so every page goes to the vision model, to score it alone.
      def initialize(dir:, provider: nil, model: nil, vision_model: nil, vision_only: false, text_extractor: Imports::TextExtractor,
        progress: nil)
        @dir = Pathname.new(dir)
        @vision_only = vision_only
        @provider = provider.presence
        @model = model.presence
        @vision_model = vision_model.presence
        @text_extractor = text_extractor
        @progress = progress # optional IO for one line per sample while the run is going
      end

      def call
        raise NoSamples, "#{@dir} does not exist" unless @dir.directory?

        samples, skipped = Sample.discover(@dir)
        raise NoSamples, no_samples_message(skipped) if samples.empty?

        Ai::Config.with(provider: @provider, extraction_model: @model, extraction_vision_model: @vision_model) do
          provider = Ai::Config.provider
          Ai::Config.ensure_ready!(provider)
          rows = []
          stopped = nil
          samples.each do |sample|
            row = run(sample)
            rows << row
            @progress&.puts("#{sample.name}: #{row.error || "done"}")
            if row.quota
              stopped = "Stopped after #{rows.size} of #{samples.size} samples: the provider's quota is used up. Re-run after 00:05 UTC."
              break
            end
          end

          Report.new(rows: rows, skipped: skipped, dir: @dir, provider: provider, model: Ai::Config.extraction_model(provider),
            vision_model: Ai::Config.extraction_vision_model(provider), vision_only: @vision_only, stopped: stopped)
        end
      end

      private
        def run(sample)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          expected = sample.expected
          ocr = @text_extractor.new(sample.path, content_type: sample.content_type).call
          text = @vision_only ? ocr.pages.map { |page| "=== page #{page.number} ===\n" }.join("\n") : ocr.text
          result = Imports::Extractor.for_file(sample.path.to_s, content_type: sample.content_type, text: text).call
          Row.new(sample: sample, score: Scorer.new(expected: expected, actual: with_final_expiry(result.data)).call, units: result.units,
            input_tokens: result.input_tokens, output_tokens: result.output_tokens, requests: result.requests,
            seconds: elapsed(started), error: nil, quota: false)
        rescue Ai::ConfigurationError
          raise
        rescue Ai::QuotaExceeded => error
          failed_row(sample, error.message, started, quota: true)
        rescue JSON::ParserError => error
          failed_row(sample, "#{sample.expected_path.basename} is not valid JSON: #{error.message.truncate(80)}", started)
        rescue StandardError => error
          failed_row(sample, "#{error.class.name.demodulize}: #{error.message.truncate(120)}", started)
        end

        # Answer files hold the expiry the certificate ends up with, so each returned certificate is
        # scored on the date the pipeline would propose from what the model read (Imports::DateRules).
        def with_final_expiry(data)
          certificates = Array(data["certificates"]).map do |certificate|
            type = Imports::TypeMatcher.new(code: certificate["certificate_type_code"], name_as_printed: certificate["certificate_name_as_printed"]).call.type
            dates = Imports::DateRules.new(completed_on: certificate["completed_on"], expires_on: certificate["expires_on"],
              validity_months: certificate["validity_months"], no_expiration: certificate["no_expiration"], certificate_type: type).call
            certificate.merge("expires_on" => dates.expires_on&.iso8601)
          end
          data.merge("certificates" => certificates)
        end

        def failed_row(sample, message, started, quota: false)
          Row.new(sample: sample, score: nil, units: 0, input_tokens: 0, output_tokens: 0, requests: 0,
            seconds: elapsed(started), error: message, quota: quota)
        end

        def elapsed(started)
          (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
        end

        def no_samples_message(skipped)
          lines = [ "No samples to score in #{@dir}. Add certificate files with a <name>.expected.json beside each " \
            "(docs/IMPORT_SPIKE.md)." ]
          lines.concat(skipped.map { |note| "  skipped #{note}" })
          lines.join("\n")
        end
    end
  end
end
