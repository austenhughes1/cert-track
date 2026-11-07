module Imports
  # Adds what a card names but nothing on file matches, so a reviewer isn't asked to (owner, Nov 6,
  # 2026): a crew member from the holder's name, a certificate type from the printed name, an issuer
  # from the printed issuer. Only when the match found nobody: a near match stays a suggestion for a
  # person to confirm ("Rash Williams" is not a new crew member). Stored names may be misread, and
  # duplicates are accepted for now and can be cleaned up later.
  #
  #   Imports::CreateMissingRecords.new(item).call # updates the item's matches; returns nothing useful
  #
  # A holder name needs a first and a last name; without one the item waits for a person. An advisory
  # lock on the name means two items read at once make one crew member, not two.
  class CreateMissingRecords
    CREATED_NOTE = "created from this item".freeze

    def initialize(item)
      @item = item
    end

    def call
      attributes = [ crew_member_match, type_match, issuer_match ].compact.reduce({}, :merge)
      @item.update!(attributes) if attributes.any?
    end

    private
      def crew_member_match
        return unless @item.person_unmatched? && @item.matched_crew_member_id.nil?

        name = CreateCrewMember.suggested_attributes(@item)
        return if name.values_at(:first_name, :last_name).any?(&:blank?)

        CrewMember.transaction do
          lock("crew:#{NameNormalizer.normalize(@item.holder_name_raw)}")
          found = PersonMatcher.new(@item.holder_name_raw).call
          next unless found.match == :unmatched || found.match == :matched

          member = found.crew_member || CrewMember.create!(name.merge(active: true))
          { matched_crew_member: member, person_match: :matched,
            person_suggestions: [ entry(member), *others(@item.person_suggestions, member) ].first(PersonMatcher::MAX_SUGGESTIONS) }
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

      def lock(key)
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
