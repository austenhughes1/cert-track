require "test_helper"
require_relative "eval_test_support"

class Imports::Eval::RunnerTest < ActiveSupport::TestCase
  include EvalTestSupport

  setup { AiUsageDay.delete_all }
  teardown { Ai::FakeProvider.reset! }

  test "scores every sample with the fake provider and meets the bar on synthetic certificates" do
    with_samples_dir do |dir|
      write_sample(dir, "ortiz_osha30", {})
      write_sample(dir, "li_flagger_pack", :outline, { holder: "Li Chen", name: "Flagger Certification", expires: "2028-03-14" })

      report = Imports::Eval::Runner.new(dir: dir, provider: "fake").call

      assert_equal [ "li_flagger_pack.pdf", "ortiz_osha30.pdf" ], report.rows.map { |row| row.sample.name }
      assert_nil report.rows.map(&:error).compact.first
      Imports::Eval::Scorer::SCORED_FIELDS.each { |field| assert_equal 100.0, report.percent(field), field }
      assert report.meets_bar?
      assert_equal 2, report.total(:requests)
      assert_operator report.total(:units), :>, 0
      assert_equal "fake-extractor", report.model
    end
  end

  test "a wrong answer pulls a field below the 90% bar, and the table says where" do
    with_samples_dir do |dir|
      expected = expected_for([ {} ])
      expected["certificates"].first["expires_on"] = "2030-01-01"
      write_sample(dir, "ortiz_osha30", {}, expected: expected)

      report = Imports::Eval::Runner.new(dir: dir, provider: "fake").call
      text = report.to_s

      assert_equal 0.0, report.percent("expires_on")
      assert_equal [ "expires_on" ], report.below_bar
      assert_not report.meets_bar?
      assert_match 'expires: want "2030-01-01", got nil', text
      assert_match "Verdict: below the 90% bar on expires.", text
      assert_match(/expires\s+0\/1\s+0\.0%\s+below the bar/, text)
      assert_match(/holder\s+1\/1\s+100\.0%\s+meets the bar/, text)
      assert_match(/number\s+1\/1\s+100\.0%\s+\(informational\)/, text)
    end
  end

  test "a quota error stops the run and keeps the rows done so far" do
    with_samples_dir do |dir|
      %w[a b c].each { |name| write_sample(dir, name, {}) }
      calls = 0
      extractor = Class.new(Imports::TextExtractor) do
        define_method(:call) do
          calls += 1
          Ai::FakeProvider.fail_next! if calls == 2
          super()
        end
      end

      report = Imports::Eval::Runner.new(dir: dir, provider: "fake", text_extractor: extractor).call

      assert_equal 2, report.rows.size
      assert report.rows.last.quota
      assert_match "Stopped after 2 of 3 samples", report.to_s
    end
  end

  test "an unreadable sample or answer file is reported and the run goes on" do
    with_samples_dir do |dir|
      dir.join("broken.pdf").binwrite("not a pdf")
      dir.join("broken.expected.json").write('{"certificates":[]}')
      write_sample(dir, "good", {})
      dir.join("good.expected.json").write("{oops")

      report = Imports::Eval::Runner.new(dir: dir, provider: "fake").call

      errors = report.rows.to_h { |row| [ row.sample.name, row.error ] }
      assert_match "could not be read as a PDF", errors.fetch("broken.pdf")
      assert_match "good.expected.json is not valid JSON", errors.fetch("good.pdf")
      assert_match "Errors: 2.", report.to_s
    end
  end

  test "an empty or missing folder raises NoSamples with how to add samples" do
    with_samples_dir do |dir|
      dir.join("card.jpg").binwrite("jpg")

      error = assert_raises(Imports::Eval::Runner::NoSamples) { Imports::Eval::Runner.new(dir: dir, provider: "fake").call }
      assert_match "No samples to score", error.message
      assert_match "card.jpg: no card.expected.json", error.message
    end

    assert_raises(Imports::Eval::Runner::NoSamples) { Imports::Eval::Runner.new(dir: "/nonexistent/samples").call }
  end

  test "a provider that is not set up stops before any sample" do
    with_samples_dir do |dir|
      write_sample(dir, "card", {})

      error = assert_raises(Ai::ConfigurationError) do
        Imports::Eval::Runner.new(dir: dir, provider: "workers_ai", model: "@cf/meta/llama-3.3-70b-instruct-fp8-fast").call
      end
      assert_match "CLOUDFLARE", error.message
    end
  end

  test "the provider and models apply to the run only" do
    with_samples_dir do |dir|
      write_sample(dir, "card", {})

      report = Imports::Eval::Runner.new(dir: dir, provider: "fake", model: "fake-extractor", vision_model: "fake-vision").call

      assert_equal [ "fake", "fake-extractor", "fake-vision" ], [ report.provider, report.model, report.vision_model ]
      assert_equal "fake-extractor", Ai::FakeProvider.calls.sole.model
    end
  end

  test "vision only withholds the OCR text so every page goes to the vision model with its image" do
    with_samples_dir do |dir|
      write_sample(dir, "pack", {}, :outline)

      report = Imports::Eval::Runner.new(dir: dir, provider: "fake", vision_only: true).call

      calls = Ai::FakeProvider.calls
      assert_equal [ "fake-vision" ], calls.map(&:model).uniq
      assert_equal 2, calls.sum { |call| call.images.size }
      assert_no_match "Awarded to", calls.map(&:prompt).join
      assert_match "vision only", report.to_s
      assert_equal 0.0, report.percent("holder_name"), "the fake provider cannot read images"
    end
  end
end
