module Imports
  # Matches the holder name the model read off a card against the crew roster.
  #
  #   result = Imports::PersonMatcher.new("ORTIZ, JUAN A").call
  #   result.crew_member # => the CrewMember (the match, or the top suggestion), or nil
  #   result.match       # => :matched | :suggested | :unmatched
  #   result.suggestions # => [{ "id" => 7, "name" => "Juan Ortiz", "similarity" => 1.0 }, ...]
  #   result.basis       # => :exact | :middle_name | :close_spelling | :fuzzy | :none
  #
  # Exact: the name normalizes (NameNormalizer) to a full name, preferred + last name or alias
  # of exactly one member, who is active -> :matched. More than one exact match is ambiguous,
  # even when the others are inactive (it may be a former employee's old card) -> :suggested,
  # listing all of them, active first. An exact match on an inactive member only ->
  # :suggested ("note" => "inactive crew member"), never :matched.
  # No exact match: a name that differs only by middle names on one side
  # (CrewMember.matching_name_ignoring_middle: "Shamel Ferebee" and "Shamel Deshawn Ferebee")
  # counts as exact, by the same rules (owner, Nov 7, 2026: a card printing the middle name made
  # the crew member and the others, without it, stopped matching). Then a one-letter slip
  # (CrewMember.matching_close_spelling: "Juan Ortez" for "Juan Ortiz"), by the same rules, noted
  # CLOSE_NOTE. Each says how it matched in basis.
  # Otherwise trigram similarity (pg_trgm, on the normalized forms of every member's names):
  # the best candidate scoring Imports::Config.person_suggest_threshold or more AND beating
  # the runner-up by Imports::Config.person_margin or more -> :suggested (basis :fuzzy); else
  # :unmatched (basis :none). For either, Imports::CreateMissingRecords adds the card's holder as a
  # new crew member, marked a possible duplicate of a close one (CrewMembers::DuplicateFinder).
  # Suggestions always list up to MAX_SUGGESTIONS candidates (scoring at least
  # CrewMember::SEARCH_SIMILARITY), best first, so the reviewer has someone to pick even when
  # nothing qualifies as a suggestion.
  class PersonMatcher
    Result = Data.define(:crew_member, :match, :suggestions, :basis)

    MAX_SUGGESTIONS = 5
    INACTIVE_NOTE = "inactive crew member".freeze
    CLOSE_NOTE = "spelled slightly differently".freeze
    EPSILON = 1e-6 # similarity is a float4; keep 0.75 - 0.60 from failing a 0.15 margin

    def initialize(holder_name)
      @holder_name = holder_name.to_s.squish
      @target = NameNormalizer.normalize(@holder_name)
    end

    def call
      return Result.new(crew_member: nil, match: :unmatched, suggestions: [], basis: :none) if @target.blank?

      basis, exact = exact_candidates
      scored = scored_candidates.reject { |member, _| exact.include?(member) }

      exact.any? ? exact_result(exact, scored, basis) : fuzzy_result(scored)
    end

    private
      # [basis, members] for the first rule that finds anyone; [nil, []] when none does.
      def exact_candidates
        { exact: :matching_normalized_name, middle_name: :matching_name_ignoring_middle, close_spelling: :matching_close_spelling }.each do |basis, finder|
          members = CrewMember.public_send(finder, @holder_name)
          return [ basis, members ] if members.any?
        end
        [ nil, [] ]
      end

      def exact_result(exact, scored, basis)
        note = CLOSE_NOTE if basis == :close_spelling
        listed = exact.map { |member| entry(member, 1.0, note:) }
        listed += scored.first([ MAX_SUGGESTIONS - listed.size, 0 ].max).map { |member, score| entry(member, score) }
        match = exact.one? && exact.first.active? ? :matched : :suggested

        Result.new(crew_member: exact.first, match:, suggestions: listed, basis:) # exact is active first
      end

      def fuzzy_result(scored)
        best, runner_up = scored.first(2)
        suggestions = scored.first(MAX_SUGGESTIONS).map { |member, score| entry(member, score) }

        if best && clear_winner?(best.last, runner_up&.last)
          Result.new(crew_member: best.first, match: :suggested, suggestions:, basis: :fuzzy)
        else
          Result.new(crew_member: nil, match: :unmatched, suggestions:, basis: :none)
        end
      end

      def clear_winner?(best, second)
        return false if best + EPSILON < Imports::Config.person_suggest_threshold

        second.nil? || best - second + EPSILON >= Imports::Config.person_margin
      end

      # [[member, similarity], ...] best first (ties: active, then name), for every member
      # whose best-scoring name reaches CrewMember::SEARCH_SIMILARITY. Names on both sides are
      # normalized in Ruby (accents, punctuation, "Last, First", middle initials) and scored
      # by pg_trgm in one query.
      def scored_candidates
        members = CrewMember.all.to_a
        pairs = members.flat_map { |member| member.normalized_names.map { |name| [ member.id, name ] } }
        return [] if pairs.empty?

        scores = similarity_by_member(pairs)
        members.filter_map { |member| [ member, scores[member.id] ] if scores[member.id].to_f >= CrewMember::SEARCH_SIMILARITY }
          .sort_by { |member, score| [ -score, member.active? ? 0 : 1, member.last_name, member.first_name, member.id ] }
      end

      def similarity_by_member(pairs)
        sql = CrewMember.sanitize_sql_array([ <<~SQL.squish, { ids: pairs.map(&:first), names: pairs.map(&:last), target: @target } ])
          SELECT t.id, max(similarity(t.name, :target)) AS score
          FROM unnest(ARRAY[:ids]::bigint[], ARRAY[:names]::text[]) AS t(id, name)
          GROUP BY t.id
        SQL
        CrewMember.connection.select_rows(sql).to_h { |id, score| [ id.to_i, score.to_f.round(3) ] }
      end

      def entry(member, similarity, note: nil)
        note = INACTIVE_NOTE unless member.active?
        { "id" => member.id, "name" => member.full_name, "similarity" => similarity.to_f.round(3), "note" => note }.compact
      end
  end
end
