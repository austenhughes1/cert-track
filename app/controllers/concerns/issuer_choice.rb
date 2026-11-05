# The issuer picker's choice in a form (shared/_issuer_picker, docs/PLAN.md Phase 3b):
# certificate_issuer_id is an issuer id, blank ("Not known"), or "other" with the typed
# other_issuer_name, which becomes an issuer (CertificateIssuer.find_or_create_from_name!, which
# reuses an issuer of that name or alias) when the form saves; other_issuer_sentence tells the user
# which it was. Without JavaScript the name field always shows, so a name typed with no issuer
# chosen counts as "Other..." too. Used by CertificatesController and ImportReviewsController.
module IssuerChoice
  extend ActiveSupport::Concern

  OTHER = CertificateIssuersHelper::OTHER_VALUE
  NAME_MISSING = "Type the new issuer's name for #{CertificateIssuersHelper::OTHER_LABEL}, or choose an issuer from the list.".freeze
  ISSUER_GONE = "That issuer is no longer on the list. Choose another.".freeze
  LINK_UNUSABLE = "Verification link must be a web address, like https://www.redcross.org/...".freeze

  private
    def other_issuer_chosen?(issuer_id, other_name)
      issuer_id.to_s == OTHER || (issuer_id.blank? && other_name.present?)
    end

    # Messages for a choice that can't be saved, and for a typed verification link that isn't a web
    # address (the models would quietly drop it).
    def issuer_choice_problems(issuer_id:, other_name:, verification_url:)
      problems = []
      if other_issuer_chosen?(issuer_id, other_name)
        problems << NAME_MISSING if other_name.blank?
      elsif issuer_id.present? && !CertificateIssuer.exists?(id: issuer_id)
        problems << ISSUER_GONE
      end
      problems << LINK_UNUSABLE if verification_url.present? && Certificate.normalize_verification_url(verification_url).nil?
      problems
    end

    # The chosen issuer, or nil for none. "Other..." finds or creates it from the typed name.
    def chosen_issuer(issuer_id, other_name)
      if other_issuer_chosen?(issuer_id, other_name)
        CertificateIssuer.find_or_create_from_name!(other_name)
      elsif issuer_id.present?
        CertificateIssuer.find_by(id: issuer_id)
      end
    end

    # What a notice says about the issuer "Other..." found or added for typed_name, or nil when it
    # is an active issuer of that very name:
    #   "Granite Peak Safety was added to the issuer list; an admin can fill in how it verifies."
    #   "“Red Cross” is on the issuer list as American Red Cross, so that was used."
    #   "Summit Safety is on the issuer list but inactive; an admin can reactivate it."
    def other_issuer_sentence(issuer, typed_name)
      return if issuer.nil?
      return "#{issuer.name} was added to the issuer list; an admin can fill in how it verifies." if issuer.previously_new_record?

      typed_name = typed_name.to_s.squish
      same_name = issuer.name.casecmp?(typed_name)
      if !issuer.active?
        listed = same_name ? "#{issuer.name} is on the issuer list" : "“#{typed_name}” is on the issuer list as #{issuer.name}"
        "#{listed} but inactive; an admin can reactivate it."
      elsif !same_name
        "“#{typed_name}” is on the issuer list as #{issuer.name}, so that was used."
      end
    end

    # Yields chosen_issuer inside a transaction, so a save in the block that fails (raises, or
    # raises ActiveRecord::Rollback) leaves no new issuer behind. Returns the block's value. Not
    # for blocks that enqueue jobs (Imports::Accept): jobs are enqueued at once, not on commit,
    # so one could start before the records it needs are committed.
    def with_chosen_issuer(issuer_id, other_name)
      CertificateIssuer.transaction { yield chosen_issuer(issuer_id, other_name) }
    end
end
