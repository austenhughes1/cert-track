module Imports
  # Adds what a card names but nothing on file matches, so a reviewer isn't asked to (owner, Nov 6,
  # 2026): a crew member from the holder's name, a certificate type from the printed name, an issuer
  # from the printed issuer. Stored names may be misread, and duplicates are accepted for now.
  #
  #   Imports::CreateMissingRecords.new(item).call # updates the item's matches; returns nothing useful
  #
  # Crew members (owner, Nov 7, 2026: every card should end up on someone, a duplicate is easier to
  # fix than a card left waiting): a holder Imports::PersonMatcher matches (exactly, by middle name or
  # by a one-letter slip) is matched; one it only finds a fuzzy suggestion for, or nobody, is added
  # as a new crew member, marked a possible duplicate of the closest one
  # (CrewMembers::DuplicateFinder) for the crew page's Merge. An ambiguous name (two members fit
  # equally) or one that only fits an inactive member still waits for a person to pick, as does a
  # holder name without a first and a last name, and an item a person already matched or picked.
  # One advisory lock for every new crew member means two items read at once make one, not two.
  class CreateMissingRecords
    CREATED_NOTE = "created from this item".freeze
    CREATE_LOCK = "crew:create".freeze

    def initialize(item)
      @item = item
    end

    def call
      attributes = [ crew_member_match, type_match, issuer_match ].compact.reduce({}, :merge)
      @item.update!(attributes) if attributes.any?
    end

    private
      def crew_member_match
        return if @item.person_matched? || @item.person_picked?

        name = CreateCrewMember.suggested_attributes(@item)
        return if name.values_at(:first_name, :last_name).any?(&:blank?)

        CrewMember.transaction do
          wait_for_name(CREATE_LOCK)
          found = PersonMatcher.new(@item.holder_name_raw).call
          member = if found.match == :matched
            found.crew_member
          elsif found.match == :unmatched || found.basis == :fuzzy
            duplicate = CrewMembers::DuplicateFinder.new(@item.holder_name_raw).call
            CrewMember.create!(name.merge(active: true, possible_duplicate_of: duplicate))
          end
          next unless member

          { matched_crew_member: member, person_match: :matched,
            person_suggestions: [ entry(member), *others(found.suggestions, member) ].first(PersonMatcher::MAX_SUGGESTIONS) }
        end
      end

      def type_match
        return unless @item.type_unmatched? && @item.matched_certificate_type_id.nil? && @item.certificate_name_raw.present?

        type = CertificateType.find_or_create_from_name!(@item.certificate_name_raw)
        { matched_certificate_type: type, type_match: type.active? ? :matched : :suggested }
      end

      def issuer_match
        return unless @item.issuer_unmatched? && @item.matched_certificate_issuer_id.nil? && @item.issuer_raw.present?

        issuer = CertificateIssuer.find_or_create_from_name!(@item.issuer_raw)
        { matched_certificate_issuer: issuer, issuer_match: issuer.active? ? :matched : :suggested }
      end

      def wait_for_name(key)
        CrewMember.connection.execute(CrewMember.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", key ]))
      end

      def entry(member)
        note = CREATED_NOTE if member.previously_new_record?
        { "id" => member.id, "name" => member.full_name, "similarity" => 1.0, "note" => note }.compact
      end

      def others(suggestions, member)
        Array(suggestions).reject { |suggestion| suggestion.respond_to?(:key?) && suggestion["id"].to_i == member.id }
      end
  end
end
