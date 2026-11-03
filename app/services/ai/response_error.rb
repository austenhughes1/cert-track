module Ai
  # The provider answered, but not with the JSON object asked for. raw is the reply text.
  class ResponseError < Error
    attr_reader :raw

    def initialize(message = "AI reply was not valid JSON", raw: nil)
      @raw = raw
      super(message)
    end
  end
end
