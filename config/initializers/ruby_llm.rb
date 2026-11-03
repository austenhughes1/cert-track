# Global ruby_llm settings. Provider credentials are NOT set here: Ai::Client builds a
# RubyLLM.context per call from Ai::Config (the one place that reads the AI env vars), so only
# the providers PLAN.md allows (Workers AI, Ollama, Anthropic) can ever be configured.
RubyLLM.configure do |config|
  config.request_timeout = 120
  config.max_retries = 2
  # Request and response bodies carry certificate text (names, license numbers). ruby_llm logs
  # bodies only at DEBUG, so pin the level and ignore RUBYLLM_DEBUG.
  config.log_level = Rails.env.test? ? Logger::WARN : Logger::INFO
end
