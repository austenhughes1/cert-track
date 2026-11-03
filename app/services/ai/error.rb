module Ai
  # Base class for every error the AI layer raises. Subclasses say what the caller should do:
  # Ai::QuotaExceeded (wait for the daily reset), Ai::ConfigurationError (fix settings, don't
  # retry), Ai::ProviderError and Ai::ResponseError (transient; retry a few times).
  class Error < StandardError; end
end
