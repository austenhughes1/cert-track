require "test_helper"

class Ai::ConfigTest < ActiveSupport::TestCase
  AI_ENV = %w[AI_PROVIDER EXTRACTION_MODEL EXTRACTION_VISION_MODEL ANTHROPIC_MODEL CLOUDFLARE_ACCOUNT_ID
    CLOUDFLARE_AI_API_TOKEN ANTHROPIC_API_KEY OLLAMA_URL AI_DAILY_NEURON_BUDGET CHAT_MODEL].freeze

  setup do
    @saved_env = AI_ENV.index_with { |name| ENV[name] }
    AI_ENV.each { |name| ENV.delete(name) }
  end

  teardown do
    @saved_env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  test "the test environment always uses the fake provider, whatever AI_PROVIDER says" do
    ENV["AI_PROVIDER"] = "workers_ai"

    assert_equal "fake", Ai::Config.provider
    assert_equal "fake-extractor", Ai::Config.extraction_model
    assert_equal "fake-vision", Ai::Config.extraction_vision_model
    assert Ai::Config.ready?
  end

  test "with overrides settings for the block only, and nests" do
    Ai::Config.with(provider: "workers_ai", extraction_model: "@cf/a") do
      assert_equal "workers_ai", Ai::Config.provider
      assert_equal "@cf/a", Ai::Config.extraction_model

      Ai::Config.with(extraction_model: "@cf/b") do
        assert_equal "workers_ai", Ai::Config.provider
        assert_equal "@cf/b", Ai::Config.extraction_model
      end
      assert_equal "@cf/a", Ai::Config.extraction_model
    end

    assert_equal "fake", Ai::Config.provider
  end

  test "with takes false for no model at all, while nil leaves the setting alone" do
    Ai::Config.with(extraction_vision_model: false) do
      assert_nil Ai::Config.extraction_vision_model
      assert_equal "fake-extractor", Ai::Config.extraction_model
      assert_match "EXTRACTION_VISION_MODEL", Ai::Config.warnings.sole
      assert_match "skipped", Ai::Config.warnings.sole

      Ai::Config.with(extraction_vision_model: nil) { assert_nil Ai::Config.extraction_vision_model }
    end
    Ai::Config.with(extraction_vision_model: nil) { assert_equal "fake-vision", Ai::Config.extraction_vision_model }
  end

  test "with restores the settings when the block raises, and rejects unknown keys" do
    assert_raises(RuntimeError) { Ai::Config.with(provider: "anthropic") { raise "boom" } }
    assert_equal "fake", Ai::Config.provider

    assert_raises(ArgumentError) { Ai::Config.with(api_key: "x") { } }
  end

  test "an unknown provider is a configuration error and is reported as a problem" do
    Ai::Config.with(provider: "gemini") do
      error = assert_raises(Ai::ConfigurationError) { Ai::Config.provider }
      assert_match "workers_ai, ollama, anthropic, fake", error.message
      assert_not Ai::Config.ready?
      assert_match "gemini", Ai::Config.problems.first
    end
  end

  test "workers_ai needs the account, the token and EXTRACTION_MODEL, and says how to pick the model" do
    Ai::Config.with(provider: "workers_ai") do
      assert_nil Ai::Config.extraction_model
      assert_equal 3, Ai::Config.problems.size
      assert_match "EXTRACTION_MODEL", Ai::Config.problems.last
      assert_match "docs/IMPORT_SPIKE.md", Ai::Config.problems.last
      error = assert_raises(Ai::ConfigurationError) { Ai::Config.ensure_ready! }
      assert_match "CLOUDFLARE_AI_API_TOKEN", error.message

      ENV["CLOUDFLARE_ACCOUNT_ID"] = "acct-1"
      ENV["CLOUDFLARE_AI_API_TOKEN"] = "token"
      ENV["EXTRACTION_MODEL"] = "@cf/meta/llama-3.3-70b-instruct-fp8-fast"

      assert Ai::Config.ready?
      assert_equal "@cf/meta/llama-3.3-70b-instruct-fp8-fast", Ai::Config.extraction_model
      assert_equal "https://api.cloudflare.com/client/v4/accounts/acct-1/ai/v1", Ai::Config.workers_ai_base_url
      assert_match "EXTRACTION_VISION_MODEL", Ai::Config.warnings.first

      ENV["EXTRACTION_VISION_MODEL"] = "@cf/meta/llama-3.2-11b-vision-instruct"
      assert_empty Ai::Config.warnings
    end
  end

  test "anthropic defaults to Claude Haiku 5.5 for text and vision and needs only its key" do
    ENV["EXTRACTION_MODEL"] = "@cf/meta/llama-3.3-70b-instruct-fp8-fast"

    Ai::Config.with(provider: "anthropic") do
      assert_equal "claude-haiku-5-5", Ai::Config.extraction_model
      assert_equal "claude-haiku-5-5", Ai::Config.extraction_vision_model
      assert_equal [ "Set ANTHROPIC_API_KEY for AI_PROVIDER=anthropic." ], Ai::Config.problems

      ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
      ENV["ANTHROPIC_MODEL"] = "claude-sonnet-5-5"
      assert Ai::Config.ready?
      assert_equal "claude-sonnet-5-5", Ai::Config.extraction_model
    end
  end

  test "ollama reads EXTRACTION_MODEL and OLLAMA_URL with a local default" do
    Ai::Config.with(provider: "ollama") do
      assert_equal "http://localhost:11434/v1", Ai::Config.ollama_url
      assert_match "EXTRACTION_MODEL", Ai::Config.problems.sole

      ENV["EXTRACTION_MODEL"] = "llama3.2"
      ENV["OLLAMA_URL"] = "http://10.0.3.7:11434/v1"
      assert Ai::Config.ready?
      assert_equal "http://10.0.3.7:11434/v1", Ai::Config.ollama_url
    end
  end

  test "OLLAMA_URL must be this machine or its private network" do
    local = %w[http://localhost:11434/v1 http://127.0.0.1:11434 http://[::1]:11434/v1 http://10.1.2.3:11434
      http://172.18.0.4:11434/v1 http://192.168.1.20:11434 https://[fd12:3456::7]:11434
      http://[::ffff:10.0.0.1]:11434]
    local.each { |url| assert_nil Ai::Config.ollama_url_problem(url), url }

    # Link-local too: 169.254.169.254 is the cloud's instance-metadata service, outside the VM.
    %w[http://203.0.113.9:11434/v1 https://8.8.8.8/v1 http://[2001:db8::1]:11434 http://[::ffff:8.8.8.8]:11434
      http://169.254.169.254/v1 http://169.254.0.9:11434 http://[fe80::1]:11434].each do |url|
      problem = Ai::Config.ollama_url_problem(url)
      assert_match "certificate text would leave the VM", problem, url
      assert_match "nothing is sent to it", problem
    end

    assert_match "is not an http(s) URL", Ai::Config.ollama_url_problem("ftp://localhost/v1")
    assert_match "is not an http(s) URL", Ai::Config.ollama_url_problem("localhost:11434")
    assert_match "is not a valid URL", Ai::Config.ollama_url_problem("http://exa mple:1")
  end

  test "an OLLAMA_URL host name counts as local only when every address it resolves to is" do
    dns = { "cert_track-ollama" => [ "172.18.0.5" ], "mixed.example" => [ "10.0.0.2", "198.51.100.4" ],
      "gpu.example.com" => [ "198.51.100.7" ], "gone.invalid" => [] }
    problem = ->(url) { Ai::Config.ollama_url_problem(url, resolve: dns.method(:fetch)) }

    assert_nil problem.("http://cert_track-ollama:11434/v1")
    assert_match "mixed.example (198.51.100.4), which is outside", problem.("http://mixed.example:11434")
    assert_match "gpu.example.com (198.51.100.7)", problem.("https://gpu.example.com/v1")
    assert_match "gone.invalid can't be resolved", problem.("http://gone.invalid:11434")
    assert_nil Ai::Config.ollama_url_problem("http://localhost.:11434"), "a real lookup: localhost. is loopback"
  end

  test "a non-local OLLAMA_URL is a blocking problem for ollama only, so nothing is sent" do
    ENV["EXTRACTION_MODEL"] = "llama3.2"
    ENV["OLLAMA_URL"] = "http://203.0.113.9:11434/v1"

    Ai::Config.with(provider: "ollama") do
      assert_not Ai::Config.ready?
      assert_match "OLLAMA_URL points at 203.0.113.9", Ai::Config.problems.sole
      error = assert_raises(Ai::ConfigurationError) { Ai::Config.ensure_ready! }
      assert_match "certificate text would leave the VM", error.message
    end

    assert Ai::Config.ready?, "the fake provider ignores OLLAMA_URL"
    ENV["CLOUDFLARE_ACCOUNT_ID"] = "acct-1"
    ENV["CLOUDFLARE_AI_API_TOKEN"] = "token"
    Ai::Config.with(provider: "workers_ai") { assert Ai::Config.ready? }
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
    Ai::Config.with(provider: "anthropic") { assert Ai::Config.ready? }
  end

  test "daily budget defaults to 9000 and ignores junk" do
    assert_equal 9000, Ai::Config.daily_budget

    ENV["AI_DAILY_NEURON_BUDGET"] = "4500"
    assert_equal 4500, Ai::Config.daily_budget

    ENV["AI_DAILY_NEURON_BUDGET"] = "lots"
    assert_equal 9000, Ai::Config.daily_budget
    ENV["AI_DAILY_NEURON_BUDGET"] = "-5"
    assert_equal 9000, Ai::Config.daily_budget

    Ai::Config.with(daily_budget: 50) { assert_equal 50, Ai::Config.daily_budget }
  end

  test "only workers_ai and fake have a daily allocation" do
    assert Ai::Config.daily_allocation?("workers_ai")
    assert Ai::Config.daily_allocation?("fake")
    assert_not Ai::Config.daily_allocation?("anthropic")
    assert_not Ai::Config.daily_allocation?("ollama")
  end

  test "model settings come from config/ai_models.yml with conservative defaults for unknown models" do
    known = Ai::Config.model_settings("@cf/meta/llama-3.3-70b-instruct-fp8-fast")
    assert_equal 26_668, known[:input_per_million]
    assert_equal 204_805, known[:output_per_million]
    assert known[:known]
    assert Ai::Config.structured_output?("@cf/meta/llama-3.3-70b-instruct-fp8-fast")
    assert_not Ai::Config.structured_output?("@cf/google/gemma-3-12b-it")
    assert_equal 1, Ai::Config.max_images("@cf/meta/llama-3.2-11b-vision-instruct")

    unknown = Ai::Config.model_settings("@cf/someone/new-model")
    assert_not unknown[:known]
    assert_operator unknown[:output_per_million], :>=, known[:output_per_million]
    assert_equal 1, Ai::Config.max_images("@cf/someone/new-model")
  end

  test "every model in config/ai_models.yml has numeric rates" do
    catalog = YAML.safe_load_file(Rails.root.join("config/ai_models.yml"))

    catalog.fetch("models").each_key do |model|
      settings = Ai::Config.model_settings(model)
      %i[input_per_million output_per_million per_image].each do |key|
        assert_kind_of Numeric, settings[key], "#{model} #{key}"
      end
    end
  end

  test "chat model is a placeholder read from CHAT_MODEL" do
    assert_nil Ai::Config.chat_model
    ENV["CHAT_MODEL"] = "@cf/meta/llama-3.3-70b-instruct-fp8-fast"
    assert_equal "@cf/meta/llama-3.3-70b-instruct-fp8-fast", Ai::Config.chat_model
  end
end
