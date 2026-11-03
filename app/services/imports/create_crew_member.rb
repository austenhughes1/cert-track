module Imports
  # "Create crew member from this": adds the card's holder to the roster and matches the item to them.
  #
  #   Imports::CreateCrewMember.suggested_attributes(item) # => { first_name: "Juan", last_name: "Ortiz" }
  #   member = Imports::CreateCrewMember.new(item, user: Current.user, attributes: { first_name: "Juan", last_name: "Ortiz" }).call
  #
  # attributes may hold first_name, last_name, preferred_name, email, phone, employer,
  # crew_role_id and notes. The item must be in the review queue (else
  # Imports::Accept::NotReviewable). Sets matched_crew_member and person_match :matched, and
  # puts the new member first in person_suggestions. The printed spelling becomes an alias
  # when the item is accepted (Imports::Accept), if it differs from the name entered here.
  # Raises ActiveRecord::RecordInvalid with the member's errors (e.g. "Last name can't be blank").
  class CreateCrewMember
    PERMITTED_ATTRIBUTES = %i[first_name last_name preferred_name email phone employer crew_role_id notes].freeze

    class << self
      # First and last name read from item.holder_name_raw, to prefill the form: "ORTIZ, JUAN A"
      # and "Juan A. Ortiz" both give Juan / Ortiz. Middle initials are dropped, every later
      # word is the last name ("Maria Garcia Lopez" -> Maria / Garcia Lopez) and ALL CAPS or
      # all-lowercase names are capitalized.
      def suggested_attributes(item)
        raw = item.holder_name_raw.to_s.squish
        last, first = raw.split(",", 2).map(&:squish) if raw.count(",") == 1
        tokens = (first.present? && last.present? ? "#{first} #{last}" : raw).delete(",").split
        first_name, *rest = tokens
        surname = rest.reject { |token| token.delete(".").length == 1 }.presence || rest

        { first_name: capitalize(first_name.to_s), last_name: capitalize(surname.join(" ")) }
      end

      private
        def capitalize(name)
          return name unless name == name.upcase || name == name.downcase

          name.split(" ").map { |word| word.split(/([-'’])/).map(&:capitalize).join }.join(" ")
        end
    end

    def initialize(item, user:, attributes: {})
      @item = item
      @user = user
      @attributes = attributes.to_h.with_indifferent_access.slice(*PERMITTED_ATTRIBUTES)
    end

    def call
      member = ImportItem.transaction do
        Imports::Accept.lock_for_review!(@item)
        member = CrewMember.create!(@attributes.merge(active: true))
        @item.update!(matched_crew_member: member, person_match: :matched, person_suggestions: suggestions_with(member))
        member
      end

      @item.import_batch.check_completion!
      member
    end

    private
      def suggestions_with(member)
        others = Array(@item.person_suggestions).reject { |suggestion| suggestion.respond_to?(:key?) && suggestion["id"].to_i == member.id }
        [ { "id" => member.id, "name" => member.full_name, "similarity" => 1.0, "note" => "created from this item" }, *others ]
          .first(Imports::PersonMatcher::MAX_SUGGESTIONS)
      end
  end
end
