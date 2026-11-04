require "ipaddr"
require "socket"

module Ai
  # Every AI setting, in one place. Values come from ENV (declared in config/deploy.yml and the
  # env tables in docs/DEPLOY.md section 7 and docs/PLAN.md) and per-model data from
  # config/ai_models.yml. Nothing else in app/ reads these variables.
  #
  #   Ai::Config.provider                 # => "workers_ai" | "ollama" | "anthropic" | "fake"
  #   Ai::Config.extraction_model         # => "@cf/meta/llama-3.3-70b-instruct-fp8-fast" or nil
  #   Ai::Config.ready?                   # => false until EXTRACTION_MODEL and the keys are set
  #   Ai::Config.problems                 # => ["Set EXTRACTION_MODEL ..."] for the UI
  #   Ai::Config.ollama_url_problem       # => nil, or why OLLAMA_URL is refused (not on this VM's network)
  #   Ai::Config.with(provider: "fake") { ... } # scoped override (tests, the eval task)
  #   Ai::Config.with(extraction_vision_model: false) { ... } # false: no model at all (nil: no override)
  #
  # The test environment always uses the fake provider unless a test overrides it with .with,
  # so no test can reach a real API even when AI_PROVIDER is set in the shell.
  #
  # PLAN.md allows Ollama only as a local model: certificate text may leave the VM only for
  # Cloudflare and (when switched on) Anthropic. So with AI_PROVIDER=ollama, an OLLAMA_URL whose
  # host isn't loopback or a private network is a blocking problem (ensure_ready! raises before
  # any call): localhost, an IP literal in 127.0.0.0/8, ::1, 10/8, 172.16/12, 192.168/16,
  # fc00::/7, or a name that resolves only to such addresses (a Kamal accessory such as
  # cert_track-ollama on the Docker network). Link-local is refused: 169.254.169.254 is the
  # cloud's instance-metadata service, which is outside the VM. The name is checked when the problems are,
  # i.e. before each import's AI step; this guards against a config mistake, not DNS tricks.
  module Config
    PROVIDERS = %w[workers_ai ollama anthropic fake].freeze
    DEFAULT_PROVIDER = "workers_ai"
    # Providers with a free daily allocation that resets at 00:00 UTC (Ai::Budget applies).
    DAILY_ALLOCATION_PROVIDERS = %w[workers_ai fake].freeze
    DEFAULT_DAILY_BUDGET = 9000
    DEFAULT_ANTHROPIC_MODEL = "claude-haiku-5-5"
    DEFAULT_OLLAMA_URL = "http://localhost:11434/v1"
    OLLAMA_RESOLVE_TIMEOUT = 2 # seconds to look up OLLAMA_URL's host
    FAKE_MODEL = "fake-extractor"
    FAKE_VISION_MODEL = "fake-vision"
    WORKERS_AI_BASE_URL = "https://api.cloudflare.com/client/v4/accounts/%s/ai/v1"
    OVERRIDABLE = %i[provider extraction_model extraction_vision_model daily_budget].freeze
    MODELS_FILE = "config/ai_models.yml"
    SPIKE_DOC = "docs/IMPORT_SPIKE.md"

    class << self
      # The provider every AI call uses. Raises Ai::ConfigurationError for an unknown value.
      def provider
        value = override(:provider) || (Rails.env.test? ? "fake" : ENV["AI_PROVIDER"].presence || DEFAULT_PROVIDER)
        value = value.to_s.strip.downcase
        return value if PROVIDERS.include?(value)

        raise ConfigurationError, "AI_PROVIDER is #{value.inspect}; use one of #{PROVIDERS.join(", ")}."
      end

      def daily_allocation?(provider = self.provider)
        DAILY_ALLOCATION_PROVIDERS.include?(provider.to_s)
      end

      # Model id for text extraction, or nil when it has not been chosen yet.
      # Anthropic uses ANTHROPIC_MODEL (default claude-haiku-5-5) so switching AI_PROVIDER to
      # anthropic for a backlog run does not also mean editing EXTRACTION_MODEL.
      def extraction_model(provider = self.provider)
        model_override(:extraction_model) { default_model(provider, vision: false) }
      end

      # Model id for pages whose OCR text is unusable, or nil when not chosen.
      def extraction_vision_model(provider = self.provider)
        model_override(:extraction_vision_model) { default_model(provider, vision: true) }
      end

      # Placeholder for Phase 4b's AI chat (chosen with certtrack:eval_chat).
      def chat_model
        ENV["CHAT_MODEL"].presence
      end

      # Neurons per UTC day the app lets itself use (AI_DAILY_NEURON_BUDGET, default 9000).
      def daily_budget
        value = override(:daily_budget) || ENV["AI_DAILY_NEURON_BUDGET"].presence
        budget = Integer(value.to_s, exception: false) if value
        budget&.positive? ? budget : DEFAULT_DAILY_BUDGET
      end

      def cloudflare_account_id
        ENV["CLOUDFLARE_ACCOUNT_ID"].presence
      end

      def cloudflare_api_token
        ENV["CLOUDFLARE_AI_API_TOKEN"].presence
      end

      # Workers AI's OpenAI-compatible endpoint for this account.
      def workers_ai_base_url
        format(WORKERS_AI_BASE_URL, cloudflare_account_id.to_s)
      end

      def anthropic_api_key
        ENV["ANTHROPIC_API_KEY"].presence
      end

      def ollama_url
        ENV["OLLAMA_URL"].presence || DEFAULT_OLLAMA_URL
      end

      # nil when ollama_url points at this machine or its private network; otherwise the
      # sentence for problems (and the job error): sending there would take data off the VM.
      # resolve: host name -> [address, ...] (a seam for tests).
      def ollama_url_problem(url = ollama_url, resolve: method(:resolve))
        uri = URI.parse(url.to_s.strip)
        host = uri.hostname.to_s.downcase
        unless %w[http https].include?(uri.scheme) && host.present?
          return "OLLAMA_URL #{url.to_s.strip.inspect} is not an http(s) URL; use a local Ollama such as #{DEFAULT_OLLAMA_URL}."
        end
        return if host == "localhost"

        addresses = ip_literal(host) ? [ host ] : resolve.call(host)
        if addresses.empty?
          "OLLAMA_URL's host #{host} can't be resolved, so it can't be checked as local: nothing is sent to it. #{ollama_rule}"
        elsif (outside = addresses.reject { |address| local_address?(address) }).any?
          "OLLAMA_URL points at #{host}#{" (#{outside.first})" if outside.first != host}, which is outside this machine and its " \
            "private network: certificate text would leave the VM, so nothing is sent to it. #{ollama_rule}"
        end
      rescue URI::InvalidURIError
        "OLLAMA_URL #{url.to_s.strip.inspect} is not a valid URL; use a local Ollama such as #{DEFAULT_OLLAMA_URL}."
      end

      # Blocking problems, as sentences for the UI and job errors. Empty when extraction can run.
      def problems(provider = nil)
        provider ||= self.provider
        missing = case provider
        when "workers_ai"
          [ ("CLOUDFLARE_ACCOUNT_ID" unless cloudflare_account_id), ("CLOUDFLARE_AI_API_TOKEN" unless cloudflare_api_token) ]
        when "anthropic" then [ ("ANTHROPIC_API_KEY" unless anthropic_api_key) ]
        else []
        end.compact
        list = missing.map { |name| "Set #{name} for AI_PROVIDER=#{provider}." }
        list << ollama_url_problem if provider == "ollama"
        list << missing_model_message(provider, "EXTRACTION_MODEL") unless extraction_model(provider)
        list.compact
      rescue ConfigurationError => error
        [ error.message ]
      end

      # Non-blocking gaps: text extraction works, but pages OCR can't read are skipped.
      def warnings(provider = nil)
        provider ||= self.provider
        return [] if extraction_vision_model(provider)

        [ missing_model_message(provider, "EXTRACTION_VISION_MODEL") + " Until then, pages whose OCR text is unreadable " \
          "are skipped (the reviewer is told which), and a file with nothing else readable fails." ]
      rescue ConfigurationError
        []
      end

      def ready?(provider = nil)
        problems(provider).empty?
      end

      def ensure_ready!(provider = nil)
        list = problems(provider)
        raise ConfigurationError, "AI extraction is not configured: #{list.join(" ")}" if list.any?
      end

      # Settings for model from config/ai_models.yml, falling back to the "default" entry:
      # { input_per_million:, output_per_million:, per_image:, structured_output:, vision:, max_images: }
      def model_settings(model)
        catalog = models_catalog
        defaults = catalog.fetch("default", {})
        entry = catalog.fetch("models", {}).fetch(model.to_s, {})
        defaults.merge(entry).symbolize_keys.tap do |settings|
          settings[:known] = catalog.fetch("models", {}).key?(model.to_s)
        end
      end

      def structured_output?(model)
        model_settings(model)[:structured_output] == true
      end

      def max_images(model)
        [ model_settings(model)[:max_images].to_i, 1 ].max
      end

      # Runs the block with settings overridden (fiber-local, restored afterwards):
      #   Ai::Config.with(provider: "workers_ai", extraction_model: "@cf/...") { ... }
      def with(**overrides)
        unknown = overrides.keys - OVERRIDABLE
        raise ArgumentError, "unknown Ai::Config override: #{unknown.join(", ")}" if unknown.any?

        previous = current_overrides
        ActiveSupport::IsolatedExecutionState[:ai_config_overrides] = previous.merge(overrides.compact)
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[:ai_config_overrides] = previous if previous
      end

      private
        def override(key)
          current_overrides[key]
        end

        # The overridden model id; false means "no model"; no override runs the block.
        def model_override(key)
          value = override(key)
          value.nil? ? yield : value.presence
        end

        def current_overrides
          ActiveSupport::IsolatedExecutionState[:ai_config_overrides] || {}
        end

        def default_model(provider, vision:)
          case provider
          when "fake" then vision ? FAKE_VISION_MODEL : FAKE_MODEL
          when "anthropic" then ENV["ANTHROPIC_MODEL"].presence || DEFAULT_ANTHROPIC_MODEL
          else vision ? ENV["EXTRACTION_VISION_MODEL"].presence : ENV["EXTRACTION_MODEL"].presence
          end
        end

        def missing_model_message(provider, variable)
          if provider == "workers_ai"
            "Set #{variable}: the Phase 3 accuracy spike picks it (#{SPIKE_DOC}), then it goes in config/deploy.yml."
          else
            "Set #{variable} to a model available on #{provider}."
          end
        end

        def models_catalog
          @models_catalog ||= YAML.safe_load_file(Rails.root.join(MODELS_FILE)).freeze
        end

        def ollama_rule
          "Ollama is allowed only as a local model (docs/PLAN.md): use localhost, a private address or the " \
            "Kamal accessory's name."
        end

        def ip_literal(host)
          IPAddr.new(host)
        rescue IPAddr::Error
          nil
        end

        # Every address host resolves to ([] when it doesn't resolve).
        def resolve(host)
          Addrinfo.getaddrinfo(host, nil, nil, :STREAM, timeout: OLLAMA_RESOLVE_TIMEOUT).map(&:ip_address).uniq
        rescue SocketError, IO::TimeoutError # Socket::ResolutionError is a SocketError
          []
        end

        def local_address?(address)
          ip = IPAddr.new(address.to_s.sub(/%.*\z/, "")) # drop an IPv6 zone ("fe80::1%eth0")
          ip.loopback? || ip.private?
        rescue IPAddr::Error
          false
        end
    end
  end
end
