require "test_helper"

class Imports::ConfigTest < ActiveSupport::TestCase
  test "limits and thresholds are the PLAN.md values" do
    assert_equal 500.megabytes, Imports::Config.max_batch_bytes
    assert_equal 2_000, Imports::Config.max_entries
    assert_equal 2.gigabytes, Imports::Config.max_uncompressed_bytes
    assert_equal 2, Imports::Config.max_zip_depth
    assert_equal 0.85, Imports::Config.auto_accept_confidence
    assert_equal 0.6, Imports::Config.person_suggest_threshold
    assert_equal 0.15, Imports::Config.person_margin
    assert_equal 0.45, Imports::Config.type_suggest_threshold
    assert_equal 40, Imports::Config.ocr_min_chars
  end

  test "supported content types and zips" do
    assert_equal %w[application/pdf image/jpeg image/png image/heic image/heif image/webp], Imports::Config.supported_content_types
    assert Imports::Config.supported?("image/heic")
    assert_not Imports::Config.supported?("application/zip")
    assert_not Imports::Config.supported?(nil)
    assert Imports::Config.zip?("application/x-zip-compressed")
    assert_not Imports::Config.zip?("application/pdf")
    assert_includes Imports::Config.upload_content_types, "application/zip"
    assert_includes Imports::Config.upload_content_types, "image/webp"
  end

  test "auto-accept is off unless AUTO_ACCEPT_ENABLED is exactly true" do
    with_env("AUTO_ACCEPT_ENABLED" => nil) { assert_not Imports::Config.auto_accept_enabled? }
    with_env("AUTO_ACCEPT_ENABLED" => "false") { assert_not Imports::Config.auto_accept_enabled? }
    with_env("AUTO_ACCEPT_ENABLED" => "1") { assert_not Imports::Config.auto_accept_enabled? }
    with_env("AUTO_ACCEPT_ENABLED" => "true") { assert Imports::Config.auto_accept_enabled? }
  end

  test "with overrides values for the block only, nested, and restores them after an error" do
    Imports::Config.with(max_entries: 3, auto_accept_enabled: true) do
      assert_equal 3, Imports::Config.max_entries
      assert Imports::Config.auto_accept_enabled?

      Imports::Config.with(max_entries: 5) do
        assert_equal 5, Imports::Config.max_entries
        assert Imports::Config.auto_accept_enabled?
      end
      assert_equal 3, Imports::Config.max_entries
    end
    assert_equal 2_000, Imports::Config.max_entries

    assert_raises(RuntimeError) { Imports::Config.with(max_zip_depth: 0) { raise "boom" } }
    assert_equal 2, Imports::Config.max_zip_depth

    with_env("AUTO_ACCEPT_ENABLED" => "true") do
      Imports::Config.with(auto_accept_enabled: false) { assert_not Imports::Config.auto_accept_enabled? }
    end
  end

  test "with rejects unknown settings" do
    error = assert_raises(ArgumentError) { Imports::Config.with(max_files: 1) { flunk "block ran" } }
    assert_match "max_files", error.message
  end

  test "overrides don't leak to other threads" do
    Imports::Config.with(max_entries: 1) do
      assert_equal 2_000, Thread.new { Imports::Config.max_entries }.value
    end
  end

  private
    def with_env(values)
      previous = values.keys.index_with { |key| ENV[key] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| ENV[key] = value }
    end
end
