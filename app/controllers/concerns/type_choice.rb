# The certificate type picker's choice in a form: certificate_type_id is a type's id, or "other" with
# the typed other_type_name, which becomes a certificate type (CertificateType.find_or_create_from_name!,
# which reuses a type of that name or alias) when the form saves. There is no type called Other; a
# name that is merely close makes a new type, and duplicates can be cleaned up later (owner, Nov 5,
# 2026). Used by CertificatesController and ImportReviewsController.
module TypeChoice
  extend ActiveSupport::Concern

  TYPE_NAME_MISSING = "Type the new certificate type's name for #{CertificateIssuersHelper::OTHER_LABEL}, or choose a type from the list.".freeze

  private
    def other_type_chosen?(type_id)
      type_id.to_s == CertificateIssuersHelper::OTHER_VALUE
    end

    def type_choice_problems(type_id:, other_name:)
      other_type_chosen?(type_id) && other_name.blank? ? [ TYPE_NAME_MISSING ] : []
    end

    # What a notice says about the type "Other..." found or added for typed_name, or nil when it is an
    # active type of that very name.
    #   "Scaffold Safety was added to the certificate types, valid 24 months; an admin can change that."
    #   "“HazCom” is listed as Hazard Communication, so that was used."
    def other_type_sentence(type, typed_name)
      return if type.nil?
      if type.previously_new_record?
        return "#{type.name} was added to the certificate types, valid #{type.validity_months} months; an admin can change that."
      end

      typed_name = typed_name.to_s.squish
      same_name = type.name.casecmp?(typed_name)
      listed = same_name ? "#{type.name} is listed" : "“#{typed_name}” is listed as #{type.name}"
      if !type.active?
        "#{listed} but retired; an admin can reactivate it."
      elsif !same_name
        "#{listed}, so that was used."
      end
    end
end
