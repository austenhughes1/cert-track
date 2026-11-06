module Ai
  # The only code that talks to ruby_llm. One call in, one parsed JSON reply out:
  #
  #   client = Ai::Client.new(model: Ai::Config.extraction_model)
  #   response = client.json(system: "...", prompt: "...", schema: { name: "x", schema: {...} },
  #                          images: ["/tmp/page-2.jpg"])
  #   response.data   # => Hash (or Array) parsed from the reply
  #   response.units  # => neurons (Workers AI) or tokens, already recorded in ai_usage_days
  #
  # Providers are an allowlist (Ai::Config::PROVIDERS): Workers AI through its OpenAI-compatible
  # endpoint, a local Ollama, Anthropic when switched on, and Ai::FakeProvider. Certificate data
  # goes nowhere else: an OLLAMA_URL off this machine's network raises Ai::ConfigurationError
  # before anything is sent. Usage is recorded for every reply that comes back, even one that fails to
  # parse, because the provider has already counted it. Before every call to a provider with a
  # daily allocation, today's usage is checked: once it reaches Ai::Config.daily_budget the call
  # is not sent and Ai::QuotaExceeded is raised (Ai::Budget.exhausted?).
  #
  # Errors: Ai::QuotaExceeded (the daily budget is used up, HTTP 429, Workers AI's daily free
  # allocation, payment required), Ai::ConfigurationError (bad credentials or settings),
  # Ai::ProviderError (anything else from the provider or the network), Ai::ResponseError (the
  # reply is not JSON).
  #
  # transport: is a seam for tests: a callable that receives the configured RubyLLM::Chat (with
  # the user message staged) and returns the assistant RubyLLM::Message. The default sends it.
  class Client
    Reply = Data.define(:content, :input_tokens, :output_tokens, :finish_reason) do
      def initialize(content:, input_tokens:, output_tokens:, finish_reason: nil) = super
    end
    Response = Data.define(:data, :content, :provider, :model, :input_tokens, :output_tokens, :images, :units)

    # Workers AI defaults max_tokens to 256, far too few for a multi-certificate file.
    DEFAULT_MAX_OUTPUT_TOKENS = 2048
    # Claude Haiku 5.5 thinks adaptively by default, and thinking counts against max_tokens.
    ANTHROPIC_MIN_OUTPUT_TOKENS = 8_000
    REQUEST_TIMEOUT = 120 # seconds
    MAX_RETRIES = 2 # ruby_llm retries 429/5xx/timeouts this many times before raising
    RUBY_LLM_PROVIDERS = { "workers_ai" => :openai, "ollama" => :ollama, "anthropic" => :anthropic }.freeze
    # "Credit balance" and "usage limit" are an Anthropic account out of funds or at its spend limit:
    # files wait for a top-up or a higher limit rather than fail.
    QUOTA_PATTERN = /daily free allocation|free allocation|\b4006\b|quota|rate.?limit|too many requests|credit balance|usage limit/i
    SCHEMA_REJECTED_PATTERN = /response_format|json_schema|json mode|structured output|schema/i
    RETRY_WITHOUT_DAILY_RESET = 15.minutes # a 429 from a provider with no daily allocation
    THINK_BLOCK = %r{<think>.*?</think>}m
    FENCED_BLOCK = /```(?:json)?\s*(.*?)```/m

    attr_reader :provider, :model

    def initialize(model:, provider: Ai::Config.provider, transport: nil)
      @provider = provider.to_s
      unless Ai::Config::PROVIDERS.include?(@provider)
        raise ConfigurationError, "Unknown AI provider #{@provider.inspect}; use one of #{Ai::Config::PROVIDERS.join(", ")}."
      end
      raise ConfigurationError, "No model is set for AI_PROVIDER=#{@provider}." if model.blank?

      @model = model.to_s
      @transport = transport || ->(chat) { chat.complete }
    end

    # Sends system + prompt (+ page images, local JPEG paths) and returns a Response.
    # schema is { name:, schema: <JSON Schema> }: sent as structured output when
    # config/ai_models.yml says the model supports it, else described in the instructions.
    def json(system:, prompt:, schema: nil, images: [], max_output_tokens: DEFAULT_MAX_OUTPUT_TOKENS)
      ensure_budget_left!
      images = Array(images).map(&:to_s)
      reply = if provider == "fake"
        FakeProvider.new(model: model).complete(system: system, prompt: prompt, images: images)
      else
        ruby_llm_reply(system: system, prompt: prompt, schema: schema, images: images, max_output_tokens: max_output_tokens)
      end

      units = Ai::Budget.record!(provider: provider, model: model, input_tokens: reply.input_tokens,
        output_tokens: reply.output_tokens, images: images.size)
      Response.new(data: parse_reply(reply, max_output_tokens), content: reply.content, provider: provider, model: model,
        input_tokens: reply.input_tokens, output_tokens: reply.output_tokens, images: images.size, units: units)
    end

    # The configured RubyLLM::Chat for this provider and model (no user message yet). schema, when
    # given, is sent as structured output. Public so tests can render the payload (chat.render).
    def build_chat(system:, schema: nil, max_output_tokens: DEFAULT_MAX_OUTPUT_TOKENS)
      chat = ruby_llm_context.chat(model: model, provider: RUBY_LLM_PROVIDERS.fetch(provider), assume_model_exists: true)
      chat.with_instructions(system)
      chat.with_max_output_tokens(provider == "anthropic" ? [ max_output_tokens, ANTHROPIC_MIN_OUTPUT_TOKENS ].max : max_output_tokens)
      # Claude Haiku 5.5 rejects non-default sampling values; the open models get deterministic output.
      chat.with_temperature(0) unless provider == "anthropic"
      chat.with_schema(schema) if schema
      # ruby_llm's OpenAI provider writes max_completion_tokens; Workers AI reads max_tokens.
      if provider == "workers_ai"
        chat.before_request { |payload| payload[:max_tokens] = payload.delete(:max_completion_tokens) if payload.key?(:max_completion_tokens) }
      end
      chat
    rescue RubyLLM::ConfigurationError => error
      raise ConfigurationError, "#{provider} is not configured: #{error.message}"
    end

    class << self
      # Parses a model reply into a Hash or Array: plain JSON, a ```json fenced block, or the
      # outermost {...} in surrounding prose. Drops <think> blocks from reasoning models.
      def parse_json(content)
        return content if content.is_a?(Hash) || content.is_a?(Array)

        text = content.to_s.gsub(THINK_BLOCK, "").strip
        candidates = [ text, text[FENCED_BLOCK, 1], outermost_object(text) ].compact.map(&:strip).uniq
        candidates.each do |candidate|
          data = JSON.parse(candidate)
          return data if data.is_a?(Hash) || data.is_a?(Array)
        rescue JSON::ParserError
          next
        end
        raise ResponseError.new("AI reply was not a JSON object (#{text.length} characters)", raw: content)
      end

      private
        def outermost_object(text)
          start = text.index("{")
          finish = text.rindex("}")
          text[start..finish] if start && finish && finish > start
        end
    end

    private
      # docs/PLAN.md: "Before every AI call, check ai_usage_days." Nothing is sent once today's
      # (UTC) usage has reached the budget of a provider with a daily allocation.
      def ensure_budget_left!
        return unless Ai::Budget.exhausted?(provider)

        unit = Ai::Config.paid_ceiling?(provider) ? "tokens" : "neurons"
        raise QuotaExceeded, "Today's AI budget is used up (#{Ai::Budget.used_today(provider).to_fs(:delimited)} of " \
          "#{Ai::Config.daily_budget(provider).to_fs(:delimited)} #{unit}, UTC day); the next call waits for the reset."
      end

      def ruby_llm_reply(system:, prompt:, schema:, images:, max_output_tokens:)
        use_schema = schema.present? && Ai::Config.structured_output?(model)
        begin
          chat = build_chat(system: use_schema ? system : json_only(system, schema), schema: (schema if use_schema),
            max_output_tokens: max_output_tokens)
          chat.ask_later(prompt, with: images.presence)
          message = @transport.call(chat)
        rescue RubyLLM::BadRequestError => error
          # Some models advertise JSON Mode but refuse a given schema ("JSON Mode couldn't be met").
          if use_schema && error_text(error).match?(SCHEMA_REJECTED_PATTERN)
            use_schema = false
            retry
          end
          raise translate(error)
        rescue RubyLLM::Error, RubyLLM::ConfigurationError, Faraday::Error => error
          raise translate(error)
        end

        content = message.content
        tokens = message.tokens
        Reply.new(content: content, input_tokens: tokens&.input || estimate_tokens(system, prompt),
          output_tokens: tokens&.output || estimate_tokens(content), finish_reason: message.finish_reason)
      end

      def parse_reply(reply, max_output_tokens)
        self.class.parse_json(reply.content)
      rescue ResponseError => error
        raise error unless reply.finish_reason == :max_tokens

        raise ResponseError.new("AI reply was cut off at the #{max_output_tokens}-token output limit", raw: reply.content)
      end

      def ruby_llm_context
        RubyLLM.context do |config|
          config.request_timeout = REQUEST_TIMEOUT
          config.max_retries = MAX_RETRIES
          case provider
          when "workers_ai"
            config.openai_api_key = Ai::Config.cloudflare_api_token
            config.openai_api_base = Ai::Config.workers_ai_base_url
            config.openai_protocol = :chat_completions # Workers AI has no Responses API for these models
            config.openai_use_system_role = true # send "system", not OpenAI's "developer" role
          when "ollama"
            config.ollama_api_base = local_ollama_url
          when "anthropic"
            config.anthropic_api_key = Ai::Config.anthropic_api_key
          end
        end
      end

      # PLAN.md allows Ollama only as a local model. Every caller runs Ai::Config.ensure_ready!
      # first; this backstop keeps one that doesn't from sending to an OLLAMA_URL outside this
      # machine and its private network (Ai::Config.ollama_url_problem).
      def local_ollama_url
        url = Ai::Config.ollama_url
        problem = Ai::Config.ollama_url_problem(url)
        raise ConfigurationError, problem if problem

        url
      end

      def json_only(system, schema)
        instruction = "Reply with one JSON object only: no prose, no code fences."
        instruction += " It must match this JSON Schema: #{schema[:schema].to_json}" if schema.is_a?(Hash) && schema[:schema]
        "#{system}\n\n#{instruction}"
      end

      def translate(error)
        text = error_text(error).squish.truncate(300)
        if quota_error?(error, text)
          QuotaExceeded.new("#{provider} refused the request for quota: #{text}", retry_at: quota_retry_at(error))
        elsif error.is_a?(RubyLLM::UnauthorizedError) || error.is_a?(RubyLLM::ForbiddenError) || error.is_a?(RubyLLM::ConfigurationError)
          ConfigurationError.new("#{provider} rejected the credentials or settings: #{text}")
        else
          ProviderError.new("#{provider} request failed (#{error.class.name.demodulize}): #{text}")
        end
      end

      def quota_error?(error, text)
        error.is_a?(RubyLLM::RateLimitError) || error.is_a?(RubyLLM::PaymentRequiredError) ||
          response_status(error) == 429 || text.match?(QUOTA_PATTERN)
      end

      # nil for daily-allocation providers: the caller waits for Ai::Budget.next_reset_at.
      def quota_retry_at(error)
        return if Ai::Config.daily_allocation?(provider)

        seconds = Float(response_headers(error)&.[]("retry-after"), exception: false)
        wait = seconds&.positive? ? seconds.seconds.clamp(1.minute, 1.day) : RETRY_WITHOUT_DAILY_RESET
        Time.current + wait
      end

      def error_text(error)
        body = error.respond_to?(:response) ? error.response&.body : nil
        body = body.to_json if body.is_a?(Hash) || body.is_a?(Array)
        [ error.message, body ].compact_blank.uniq.join(" ")
      end

      def response_status(error)
        response = error.respond_to?(:response) ? error.response : nil
        response.respond_to?(:status) ? response.status : nil
      end

      def response_headers(error)
        response = error.respond_to?(:response) ? error.response : nil
        response.respond_to?(:headers) ? response.headers : nil
      end

      def estimate_tokens(*texts)
        (texts.sum { |text| text.to_s.length } / 4.0).ceil
      end
  end
end
