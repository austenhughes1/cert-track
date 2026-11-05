# Issuer admin pages and the issuer picker (shared/_issuer_picker), docs/PLAN.md Phase 3b.
module CertificateIssuersHelper
  OTHER_VALUE = "other".freeze
  OTHER_LABEL = "Other…".freeze

  METHOD_LABELS = {
    "unknown" => "Not known yet",
    "qr_or_code" => "QR code or code lookup",
    "code_lookup" => "Code lookup",
    "contact" => "Contact the issuer",
    "no_registry" => "No public registry"
  }.freeze

  CHECK_LABELS = {
    "aha_ecards" => "AHA eCard lookup",
    "national_cpr_foundation" => "National CPR Foundation lookup",
    "national_osha_foundation" => "National OSHA Foundation lookup",
    "osha_card_portal" => "OSHA Card Portal lookup",
    "qr_details_360training" => "360training QR details (no network)"
  }.freeze

  def certificate_issuer_method_label(issuer_or_method)
    method = issuer_or_method.respond_to?(:verification_method) ? issuer_or_method.verification_method : issuer_or_method.to_s
    METHOD_LABELS.fetch(method) { method.humanize }
  end

  # "AHA eCard lookup", or "A person checks" for an issuer without an automatic check.
  def certificate_issuer_check_label(issuer)
    return "A person checks" unless issuer.automatic_check?

    CHECK_LABELS.fetch(issuer.automatic_check) { issuer.automatic_check.humanize }
  end

  # Options for the issuer form's automatic check select.
  def certificate_issuer_check_options
    Verification::Checkers::KEYS.map { |key| [ "#{CHECK_LABELS.fetch(key) { key.humanize }} (#{key})", key ] }
  end

  # Added with "Other..." in an issuer picker and not filled in since: no method, no domains.
  def certificate_issuer_needs_details?(issuer)
    issuer.verified_by_unknown? && issuer.domains.empty?
  end

  # The issuer picker's options: the active issuers (ordered), with current first when it is
  # inactive, then "Other..." (value "other"). selected: an issuer id, "other" or blank. With
  # suggestions ([{ "id", "name", "similarity" }], an import item's issuer_suggestions) they
  # come first in a "Suggested" group, like the review queue's other pickers.
  def issuer_picker_options(issuers:, selected:, current: nil, suggestions: [])
    records = issuers.map { |issuer| [ issuer.name, issuer.id ] }
    if current && issuers.exclude?(current)
      records.unshift([ "#{current.name}#{" (inactive)" unless current.active?}", current.id ])
    end

    other_selected = selected.to_s == OTHER_VALUE
    selected_id = other_selected ? nil : selected
    listed = if Array(suggestions).any?
      import_picker_options(suggestions: suggestions, records: records, selected_id: selected_id)
    else
      options_for_select(records, selected_id.presence&.to_i)
    end
    safe_join([ listed, tag.option(OTHER_LABEL, value: OTHER_VALUE, selected: other_selected) ])
  end
end
