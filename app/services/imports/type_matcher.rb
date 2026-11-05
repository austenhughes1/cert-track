module Imports
  # Matches the certificate type the model read off a card against the certificate types.
  #
  #   result = Imports::TypeMatcher.new(code: "OSHA30", name_as_printed: "OSHA 30-Hour ...").call
  #   result.type        # => the CertificateType (the match, or the top suggestion), or nil
  #   result.match       # => :matched | :suggested | :unmatched
  #   result.suggestions # => [{ "id" => 1, "name" => "OSHA 30 Construction", "similarity" => 1.0 }, ...]
  #
  # Only a code that exists on an active type (case-insensitive) is :matched. Otherwise the
  # printed name is fuzzy-matched (pg_trgm) against active type names and aliases; a score of
  # Imports::Config.type_suggest_threshold or more is :suggested, never :matched. A code that
  # names an inactive (retired) type is only a suggestion, listed after any active candidates
  # with "note" => "inactive certificate type". Suggestions are best first, at most
  # MAX_SUGGESTIONS. A type whose name and aliases carry numbers none of which are in the printed
  # name is left out: the words of "30-hour Construction Safety" are as close to OSHA 10 as OSHA 30.
  class TypeMatcher
    Result = Data.define(:type, :match, :suggestions)

    MAX_SUGGESTIONS = 5
    INACTIVE_NOTE = "inactive certificate type".freeze

    def initialize(code:, name_as_printed:)
      @code = code.to_s.strip.presence
      @name_as_printed = name_as_printed.to_s.squish.presence
    end

    def call
      by_code = CertificateType.find_by_code(@code) if @code
      fuzzy = fuzzy_candidates

      if by_code&.active?
        others = fuzzy.reject { |type, _| type.id == by_code.id }
        suggestions = [ entry(by_code, 1.0) ] + others.first(MAX_SUGGESTIONS - 1).map { |type, score| entry(type, score) }
        return Result.new(type: by_code, match: :matched, suggestions:)
      end

      candidates = fuzzy.map { |type, score| [ type, entry(type, score) ] }
      candidates << [ by_code, entry(by_code, 1.0, note: INACTIVE_NOTE) ] if by_code
      candidates = candidates.first(MAX_SUGGESTIONS)

      if candidates.empty?
        Result.new(type: nil, match: :unmatched, suggestions: [])
      else
        Result.new(type: candidates.first.first, match: :suggested, suggestions: candidates.map(&:last))
      end
    end

    private
      def fuzzy_candidates
        return [] unless @name_as_printed

        printed = numbers_in(@name_as_printed)
        CertificateType.active.fuzzy_match(@name_as_printed, threshold: Imports::Config.type_suggest_threshold)
          .reject { |type, _| printed.any? && numbers_of(type).any? && !printed.intersect?(numbers_of(type)) }
      end

      def numbers_of(type)
        numbers_in([ type.name, *type.aliases ].join(" "))
      end

      def numbers_in(text)
        text.scan(/\d+/).to_set
      end

      def entry(type, similarity, note: nil)
        { "id" => type.id, "name" => type.name, "similarity" => similarity.to_f.round(3), "note" => note }.compact
      end
  end
end
