module Imports
  # Other items in the review queue that look like the same card as item (front and back
  # photos): the same matched person, matched type and certificate number, in any batch.
  #
  #   Imports::MergeCandidates.for(item) # => ImportItem relation, oldest first
  #
  # "Matched" means the matched_crew_member / matched_certificate_type columns, which hold a
  # match or the top suggestion. Empty unless item has all three values.
  module MergeCandidates
    def self.for(item)
      if item.matched_crew_member_id.blank? || item.matched_certificate_type_id.blank? || item.proposed_certificate_number.blank?
        return ImportItem.none
      end

      ImportItem.needs_review
        .where(matched_crew_member_id: item.matched_crew_member_id,
          matched_certificate_type_id: item.matched_certificate_type_id,
          proposed_certificate_number: item.proposed_certificate_number)
        .where.not(id: item.id)
        .order(:id)
    end
  end
end
