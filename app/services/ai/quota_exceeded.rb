module Ai
  # The provider refused the request for quota reasons: HTTP 429, Workers AI's "daily free
  # allocation" error (code 4006), or the local daily budget. retry_at, when known, is when to
  # try again; Imports::AiExtractJob otherwise waits for Ai::Budget.next_reset_at.
  class QuotaExceeded < Error
    attr_reader :retry_at

    def initialize(message = "AI quota exceeded", retry_at: nil)
      @retry_at = retry_at
      super(message)
    end
  end
end
