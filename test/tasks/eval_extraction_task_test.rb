require "test_helper"
require "rake"
require_relative "../services/imports/eval/eval_test_support"

class EvalExtractionTaskTest < ActiveSupport::TestCase
  include EvalTestSupport

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("certtrack:eval_extraction")
    Rake::Task["certtrack:eval_extraction"].reenable
    AiUsageDay.delete_all
    @saved_dir = ENV["SAMPLES_DIR"]
  end

  teardown do
    @saved_dir.nil? ? ENV.delete("SAMPLES_DIR") : ENV["SAMPLES_DIR"] = @saved_dir
    Ai::FakeProvider.reset!
  end

  test "prints per-sample results, per-field accuracy and usage for the given provider" do
    with_samples_dir do |dir|
      write_sample(dir, "ortiz_osha30", {})
      write_sample(dir, "chen_pack", { holder: "Li Chen", name: "Flagger Certification", expires: "2028-03-14" }, :outline)

      out, err = capture_io { run_task(dir, "fake", "fake-extractor") }

      assert_match "Extraction eval: provider=fake model=fake-extractor vision=fake-vision", out
      assert_match(/^chen_pack\.pdf\s+1\/1\s+1\/1/, out)
      assert_match(/^ortiz_osha30\.pdf\s+1\/1\s+1\/1/, out)
      assert_match(/type\s+2\/2\s+100\.0%\s+meets the bar/, out)
      assert_match(/completed\s+2\/2\s+100\.0%/, out)
      assert_match "Non-certificate pages: 1/1 identified", out
      assert_match(/Usage: 2 requests, [\d,]+ input tokens, [\d,]+ output tokens, [\d,]+ neurons/, out)
      assert_match "Verdict: meets the 90% bar on every scored field.", out
      assert_match "ortiz_osha30.pdf: done", err
    end
  end

  test "the vision model is the third argument" do
    with_samples_dir do |dir|
      write_sample(dir, "card", {})

      out, = capture_io { run_task(dir, "fake", "", "fake-vision") }

      assert_match "model=fake-extractor vision=fake-vision", out
    end
  end

  test "exits non-zero when the samples folder is empty" do
    with_samples_dir do |dir|
      error = assert_raises(SystemExit) { capture_io { run_task(dir, "fake") } }

      assert_not error.success?
    end
  end

  test "exits non-zero when the provider is not configured" do
    with_samples_dir do |dir|
      write_sample(dir, "card", {})

      _out, err = capture_io do
        error = assert_raises(SystemExit) { run_task(dir, "workers_ai", "@cf/meta/llama-3.3-70b-instruct-fp8-fast") }
        assert_not error.success?
      end
      assert_match "CLOUDFLARE_ACCOUNT_ID", err
    end
  end

  private
    def run_task(dir, *args)
      ENV["SAMPLES_DIR"] = dir.to_s
      Rake::Task["certtrack:eval_extraction"].invoke(*args)
    end
end
