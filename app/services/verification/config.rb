module Verification
  # Authenticity check settings (docs/PLAN.md, Phase 3b). Only VERIFICATION_AUTO_CHECKS comes from the
  # environment; the request limits are the values PLAN.md fixes ("Automatic check rules").
  #
  #   Verification::Config.auto_checks?                    # => true unless VERIFICATION_AUTO_CHECKS=false
  #   Verification::Config.http_timeout                    # => 10
  #   Verification::Config.with(auto_checks: true) { ... } # tests: override values for the block
  #
  # The test environment never runs the automatic (network) checks unless a test turns them on
  # with .with, so no test can reach an issuer's site even when the variable is set in the shell.
  module Config
    LIMITS = {
      http_timeout: 10,                    # seconds per request, from connecting to the last byte
      max_response_bytes: 1.megabyte,
      min_request_interval: 5,             # seconds between requests to one host
      daily_requests_per_host: 200,
      max_redirects: 3
    }.freeze

    USER_AGENT = "CertTrack certificate verification (+https://certs.abaventures.net)".freeze

    OVERRIDES_KEY = :verification_config_overrides
    private_constant :OVERRIDES_KEY

    class << self
      LIMITS.each_key do |name|
        define_method(name) { overrides.fetch(name) { LIMITS.fetch(name) } }
      end

      # Whether Verification::Run may ask issuers' sites (VERIFICATION_AUTO_CHECKS, default true).
      # Off, every certificate still gets the assisted check.
      def auto_checks?
        overrides.fetch(:auto_checks) { !Rails.env.test? && auto_checks_value(ENV["VERIFICATION_AUTO_CHECKS"]) } == true
      end

      # How VERIFICATION_AUTO_CHECKS reads: only "false" (any case, spaces ignored) is off.
      def auto_checks_value(value)
        value.to_s.strip.downcase != "false"
      end

      def user_agent
        USER_AGENT
      end

      # Runs the block with some values replaced (any LIMITS key, or auto_checks:), for this
      # thread or fiber only. Meant for tests.
      def with(**values)
        unknown = values.keys - LIMITS.keys - [ :auto_checks ]
        raise ArgumentError, "unknown Verification::Config settings: #{unknown.join(", ")}" if unknown.any?

        previous = overrides
        ActiveSupport::IsolatedExecutionState[OVERRIDES_KEY] = previous.merge(values)
        begin
          yield
        ensure
          ActiveSupport::IsolatedExecutionState[OVERRIDES_KEY] = previous
        end
      end

      private
        def overrides
          ActiveSupport::IsolatedExecutionState[OVERRIDES_KEY] || {}
        end
    end
  end
end
