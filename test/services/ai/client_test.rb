require "test_helper"

class Ai::ClientTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  TEXT_MODEL = "@cf/meta/llama-3.3-70b-instruct-fp8-fast".freeze
  PLAIN_MODEL = "@cf/meta/llama-3.2-11b-vision-instruct".freeze # no JSON Mode
  SCHEMA = Imports::Extraction::Schema::JSON_SCHEMA
  ENV_KEYS = %w[CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_AI_API_TOKEN ANTHROPIC_API_KEY OLLAMA_URL].freeze
  FakeResponse = Struct.new(:status, :body, :headers, keyword_init: true)

  setup do
    AiUsageDay.delete_all
    @saved_env = ENV_KEYS.index_with { |name| ENV[name] }
    ENV["CLOUDFLARE_ACCOUNT_ID"] = "acct-123"
    ENV["CLOUDFLARE_AI_API_TOKEN"] = "cf-token"
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"
    ENV.delete("OLLAMA_URL")
  end

  teardown do
    @saved_env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    Ai::FakeProvider.reset!
  end

  # --- fake provider -------------------------------------------------------------------

  test "the fake provider answers with parsed JSON and records the usage" do
    response = Ai::Client.new(provider: "fake", model: "fake-extractor").json(system: "rules", prompt: certificate_prompt)

    assert_equal "Juan A. Ortiz", response.data["certificates"].sole["holder_name"]
    assert_equal "fake", response.provider
    assert_operator response.input_tokens, :>, 0
    assert_equal response.units, AiUsageDay.used_on(Time.current.utc.to_date, "fake")
    assert_equal 1, AiUsageDay.find_by!(provider: "fake").requests
  end

  test "usage is recorded even when the reply is not JSON" do
    Ai::FakeProvider.reply_next!("Sorry, I can't read this certificate.")

    error = assert_raises(Ai::ResponseError) { Ai::Client.new(provider: "fake", model: "fake-extractor").json(system: "s", prompt: "p") }

    assert_equal "Sorry, I can't read this certificate.", error.raw
    assert_equal 1, AiUsageDay.find_by!(provider: "fake").requests
  end

  test "only allowlisted providers, and a model is required" do
    error = assert_raises(Ai::ConfigurationError) { Ai::Client.new(provider: "openai", model: "gpt-5.6") }
    assert_match "workers_ai, ollama, anthropic, fake", error.message

    error = assert_raises(Ai::ConfigurationError) { Ai::Client.new(provider: "workers_ai", model: nil) }
    assert_match "No model", error.message
  end

  # --- JSON parsing --------------------------------------------------------------------

  test "parse_json reads plain JSON, fenced blocks, JSON inside prose and skips think blocks" do
    expected = { "certificates" => [], "non_certificate_pages" => [ 1 ] }
    json = expected.to_json

    assert_equal expected, Ai::Client.parse_json(json)
    assert_equal expected, Ai::Client.parse_json("```json\n#{json}\n```")
    assert_equal expected, Ai::Client.parse_json("Here is the data:\n#{json}\nLet me know!")
    assert_equal expected, Ai::Client.parse_json("<think>page 1 is an outline {maybe}</think>\n#{json}")
    assert_equal [ { "pages" => [ 1 ] } ], Ai::Client.parse_json('[{"pages":[1]}]')
    assert_equal expected, Ai::Client.parse_json(expected)
  end

  test "parse_json raises a ResponseError for anything else" do
    [ "", "null", "42", "{not json", "Sorry." ].each do |reply|
      assert_raises(Ai::ResponseError, reply) { Ai::Client.parse_json(reply) }
    end
  end

  # --- Workers AI request shape (rendered by ruby_llm, never sent) ----------------------

  test "Workers AI goes to the account's OpenAI-compatible endpoint with JSON Mode and max_tokens" do
    chat = Ai::Client.new(provider: "workers_ai", model: TEXT_MODEL).build_chat(system: "rules", schema: SCHEMA, max_output_tokens: 2048)
    chat.ask_later("the document")
    payload = chat.render

    assert_equal "https://api.cloudflare.com/client/v4/accounts/acct-123/ai/v1", chat.provider.api_base
    assert_equal "Bearer cf-token", chat.provider.headers["Authorization"]
    assert_equal TEXT_MODEL, payload[:model]
    assert_equal 2048, payload[:max_tokens]
    assert_not payload.key?(:max_completion_tokens)
    assert_equal 0, payload[:temperature]
    assert_equal [ "system", "user" ], payload[:messages].map { |message| message[:role] }
    assert_equal "json_schema", payload.dig(:response_format, :type)
    assert_equal "certificate_extraction", payload.dig(:response_format, :json_schema, :name)
  end

  test "page images go to Workers AI as data URIs" do
    Dir.mktmpdir do |dir|
      jpeg = File.join(dir, "page-1.jpg")
      Vips::Image.black(8, 8).jpegsave(jpeg)
      chat = Ai::Client.new(provider: "workers_ai", model: "@cf/meta/llama-3.2-11b-vision-instruct").build_chat(system: "rules")
      chat.ask_later("read the page", with: [ jpeg ])

      parts = chat.render[:messages].last[:content]
      assert_equal %w[text image_url], parts.map { |part| part[:type] }
      assert_match %r{\Adata:image/jpeg;base64,}, parts.last.dig(:image_url, :url)
    end
  end

  test "missing Workers AI credentials are a configuration error" do
    ENV.delete("CLOUDFLARE_AI_API_TOKEN")

    assert_raises(Ai::ConfigurationError) { Ai::Client.new(provider: "workers_ai", model: TEXT_MODEL).build_chat(system: "rules") }
  end

  test "Anthropic gets structured output, room for adaptive thinking and no sampling parameters" do
    chat = Ai::Client.new(provider: "anthropic", model: "claude-haiku-5-5").build_chat(system: "rules", schema: SCHEMA, max_output_tokens: 2048)
    chat.ask_later("the document")
    payload = chat.render

    assert_equal "claude-haiku-5-5", payload[:model]
    assert_equal "json_schema", payload.dig(:output_config, :format, :type)
    assert_operator payload[:max_tokens], :>=, 8_000
    assert_not payload.key?(:temperature)
    assert_equal "sk-ant-test", chat.provider.headers["x-api-key"]
  end

  test "Ollama uses OLLAMA_URL, defaulting to the local server" do
    chat = Ai::Client.new(provider: "ollama", model: "llama3.2").build_chat(system: "rules")
    assert_equal "http://localhost:11434/v1", chat.provider.api_base

    ENV["OLLAMA_URL"] = "http://10.0.0.5:11434/v1"
    chat = Ai::Client.new(provider: "ollama", model: "llama3.2").build_chat(system: "rules")
    assert_equal "http://10.0.0.5:11434/v1", chat.provider.api_base
  end

  test "an OLLAMA_URL outside this machine's network is refused by the client itself, before anything is sent" do
    ENV["OLLAMA_URL"] = "http://203.0.113.7:11434/v1" # a public address (TEST-NET-3)
    sent = []
    client = Ai::Client.new(provider: "ollama", model: "llama3.2", transport: ->(chat) { sent << chat.render })

    error = assert_raises(Ai::ConfigurationError) { client.json(system: "rules", prompt: certificate_prompt) }
    assert_match "OLLAMA_URL points at 203.0.113.7, which is outside this machine", error.message
    assert_raises(Ai::ConfigurationError) { client.build_chat(system: "rules") }
    assert_empty sent
    assert_equal 0, AiUsageDay.count
  end

  # --- sending (through a stub transport) ---------------------------------------------

  test "a reply's token usage is converted to neurons and recorded on the UTC day" do
    travel_to Time.utc(2026, 11, 4, 2) do # still Nov 3 in Denver
      client = stub_client(TEXT_MODEL) { reply('{"certificates":[],"non_certificate_pages":[1]}', input: 2_000, output: 300) }
      response = client.json(system: "rules", prompt: "doc", schema: SCHEMA)

      assert_equal({ "certificates" => [], "non_certificate_pages" => [ 1 ] }, response.data)
      assert_equal [ 2_000, 300, 115 ], [ response.input_tokens, response.output_tokens, response.units ]
      assert_equal 115, AiUsageDay.used_on(Date.new(2026, 11, 4), "workers_ai")
    end
  end

  test "token counts the provider leaves out are estimated from the text" do
    client = stub_client(TEXT_MODEL) { reply('{"certificates":[]}', input: nil, output: nil) }
    response = client.json(system: "a" * 400, prompt: "b" * 400)

    assert_equal 200, response.input_tokens
    assert_equal 5, response.output_tokens
  end

  test "a model without JSON Mode gets the schema in its instructions instead" do
    payloads = []
    client = stub_client(PLAIN_MODEL, payloads) { reply("```json\n{\"certificates\":[]}\n```") }
    response = client.json(system: "rules", prompt: "doc", schema: SCHEMA)

    assert_equal({ "certificates" => [] }, response.data)
    assert_nil payloads.sole[:response_format]
    assert_match "Reply with one JSON object only", payloads.sole[:messages].first[:content]
    assert_match "non_certificate_pages", payloads.sole[:messages].first[:content]
  end

  test "a reply cut off at the output limit says so" do
    client = stub_client(TEXT_MODEL) do
      RubyLLM::Message.new(role: :assistant, content: '{"certificates":[{"pages":[1],"holder', input_tokens: 10,
        output_tokens: 2048, finish_reason: :max_tokens) # ruby_llm maps "length" to :max_tokens
    end

    error = assert_raises(Ai::ResponseError) { client.json(system: "s", prompt: "p", max_output_tokens: 2048) }
    assert_match "cut off at the 2048-token output limit", error.message
    assert_equal 1, AiUsageDay.find_by!(provider: "workers_ai").requests
  end

  test "a schema the model refuses is retried once without JSON Mode" do
    payloads = []
    calls = 0
    client = stub_client(TEXT_MODEL, payloads) do
      calls += 1
      raise RubyLLM::BadRequestError.new("AiError: JSON Mode couldn't be met (code 5025)") if calls == 1

      reply('{"certificates":[]}')
    end

    assert_equal({ "certificates" => [] }, client.json(system: "rules", prompt: "doc", schema: SCHEMA).data)
    assert_equal "json_schema", payloads.first.dig(:response_format, :type)
    assert_nil payloads.last[:response_format]
  end

  test "a 429 from Workers AI is a quota error that waits for the daily reset" do
    error = assert_raises(Ai::QuotaExceeded) do
      stub_client(TEXT_MODEL) { raise RubyLLM::RateLimitError.new("Too many requests", response: FakeResponse.new(status: 429)) }
        .json(system: "s", prompt: "p")
    end

    assert_nil error.retry_at
    assert_match "workers_ai", error.message
  end

  test "Workers AI's daily free allocation error is a quota error whatever its status" do
    body = { "errors" => [ { "message" => "AiError: 4006: you have used up your daily free allocation of 10,000 neurons, please upgrade", "code" => 4006 } ], "success" => false }
    error = assert_raises(Ai::QuotaExceeded) do
      stub_client(TEXT_MODEL) { raise RubyLLM::ForbiddenError.new(nil, response: FakeResponse.new(status: 403, body: body)) }
        .json(system: "s", prompt: "p")
    end

    assert_match "daily free allocation", error.message
  end

  test "an Anthropic account out of credit or at its spend limit waits rather than fails" do
    [ "Your credit balance is too low to access the Anthropic API.", "You have reached your specified API usage limits." ].each do |message|
      error = assert_raises(Ai::QuotaExceeded, message) do
        stub_client("claude-opus-5-5", provider: "anthropic") { raise RubyLLM::BadRequestError.new(message) }.json(system: "s", prompt: "p")
      end
      assert error.retry_at.present?, "it comes back to try again"
    end
  end

  test "a 429 from a provider without a daily allocation retries after Retry-After or 15 minutes" do
    travel_to Time.utc(2026, 11, 3, 12) do
      headers = { "retry-after" => "120" }
      error = assert_raises(Ai::QuotaExceeded) do
        stub_client("claude-haiku-5-5", provider: "anthropic") { raise RubyLLM::RateLimitError.new("rate limited", response: FakeResponse.new(status: 429, headers: headers)) }
          .json(system: "s", prompt: "p")
      end
      assert_equal Time.utc(2026, 11, 3, 12, 2), error.retry_at

      error = assert_raises(Ai::QuotaExceeded) do
        stub_client("claude-haiku-5-5", provider: "anthropic") { raise RubyLLM::RateLimitError.new("rate limited") }
          .json(system: "s", prompt: "p")
      end
      assert_equal Time.utc(2026, 11, 3, 12, 15), error.retry_at
    end
  end

  test "bad credentials are a configuration error; other failures are provider errors" do
    assert_raises(Ai::ConfigurationError) do
      stub_client(TEXT_MODEL) { raise RubyLLM::UnauthorizedError.new("Authentication error") }.json(system: "s", prompt: "p")
    end
    error = assert_raises(Ai::ProviderError) do
      stub_client(TEXT_MODEL) { raise RubyLLM::ServerError.new("upstream exploded") }.json(system: "s", prompt: "p")
    end
    assert_match "ServerError", error.message
    assert_raises(Ai::ProviderError) do
      stub_client(TEXT_MODEL) { raise Faraday::TimeoutError, "timed out" }.json(system: "s", prompt: "p")
    end
  end

  test "a failed call records no usage" do
    assert_raises(Ai::ProviderError) do
      stub_client(TEXT_MODEL) { raise RubyLLM::ServerError.new("down") }.json(system: "s", prompt: "p")
    end

    assert_equal 0, AiUsageDay.count
  end

  # --- the daily budget, before every call ---------------------------------------------

  test "nothing is sent once today's budget is used up, whoever calls" do
    travel_to Time.utc(2026, 11, 4, 15) do
      AiUsageDay.record!(provider: "workers_ai", units: Ai::Config.daily_budget, day: Date.new(2026, 11, 4))
      sent = 0
      client = stub_client(TEXT_MODEL) { sent += 1 and reply('{"certificates":[]}') }

      error = assert_raises(Ai::QuotaExceeded) { client.json(system: "s", prompt: "p") }
      assert_match "budget is used up (9,000 of 9,000 neurons", error.message
      assert_nil error.retry_at, "the caller waits for the daily reset"
      assert_equal 0, sent
      assert_equal 1, AiUsageDay.find_by!(provider: "workers_ai").requests, "the refused call is not counted"
    end
  end

  test "the budget is checked again before each call, so a run of calls stops when it runs out" do
    Ai::Config.with(daily_budget: 100) do
      client = Ai::Client.new(provider: "fake", model: "fake-extractor")
      client.json(system: "rules", prompt: certificate_prompt) while Ai::Budget.used_today("fake") < 100 && Ai::FakeProvider.calls.size < 50

      made = Ai::FakeProvider.calls.size
      assert_raises(Ai::QuotaExceeded) { client.json(system: "rules", prompt: certificate_prompt) }
      assert_equal made, Ai::FakeProvider.calls.size, "the refused call never reached the provider"
    end
  end

  test "providers without a daily allocation are never stopped by the neuron budget" do
    AiUsageDay.record!(provider: "ollama", units: 1_000_000)

    response = stub_client("llama3.2", provider: "ollama") { reply('{"certificates":[]}') }.json(system: "s", prompt: "p")

    assert_equal({ "certificates" => [] }, response.data)
  end

  private
    def certificate_prompt
      "<document>\n=== page 1 ===\nCERTIFICATE OF COMPLETION\nOSHA 30-Hour Construction Industry Outreach Training\n" \
        "Awarded to: Juan A. Ortiz\nCertificate No: 30-1234567\nCompleted: 2025-03-14\nIssued by: Example Safety Training LLC\n</document>"
    end

    # A client whose transport renders the real payload into payloads, then runs the block.
    def stub_client(model, payloads = [], provider: "workers_ai", &block)
      Ai::Client.new(provider: provider, model: model, transport: ->(chat) {
        payloads << chat.render
        block.call
      })
    end

    def reply(content, input: 100, output: 20)
      RubyLLM::Message.new(role: :assistant, content: content, input_tokens: input, output_tokens: output)
    end
end
