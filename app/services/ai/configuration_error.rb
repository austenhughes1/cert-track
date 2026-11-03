module Ai
  # AI settings are missing or invalid (unknown AI_PROVIDER, no EXTRACTION_MODEL, no API key).
  # Retrying cannot help; the message says which variable to set.
  class ConfigurationError < Error; end
end
