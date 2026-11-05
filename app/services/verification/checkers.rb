module Verification
  # Automatic authenticity checks, one class per issuer site that allows them (docs/PLAN.md, Phase 3b).
  # CertificateIssuer#automatic_check holds one of KEYS.
  #
  # Network checkers (Verification::HttpClient, only the verification code is sent):
  #   aha_ecards               Checkers::AhaEcards               ecards.heart.org, POST of the eCard code
  #   national_cpr_foundation  Checkers::NationalCprFoundation   nationalcprfoundation.com/verify/, POST
  #   national_osha_foundation Checkers::NationalOshaFoundation  nationaloshafoundation.com, GET by certificate_id
  #   osha_card_portal         Checkers::OshaCardPortal          oshacardportal.com/portalapp/verify/<code>, GET
  # Local checker (no network):
  #   qr_details_360training   Checkers::QrDetails360training    compares the holder details inside a 360training QR link
  #
  # Every checker: Checkers::<Name>.new(code:, verification_url:, holder_name:, completed_on:, expires_on:, barcodes:)
  #   #call returns a Verification::Result.
  module Checkers
    KEYS = %w[aha_ecards national_cpr_foundation national_osha_foundation osha_card_portal qr_details_360training].freeze
    NETWORK_KEYS = %w[aha_ecards national_cpr_foundation national_osha_foundation osha_card_portal].freeze

    CLASS_NAMES = {
      "aha_ecards" => "AhaEcards",
      "national_cpr_foundation" => "NationalCprFoundation",
      "national_osha_foundation" => "NationalOshaFoundation",
      "osha_card_portal" => "OshaCardPortal",
      "qr_details_360training" => "QrDetails360training"
    }.freeze

    module_function

    # The checker class for a key; KeyError for an unknown key.
    def for(key)
      const_get(CLASS_NAMES.fetch(key.to_s))
    end

    def network?(key)
      NETWORK_KEYS.include?(key.to_s)
    end
  end
end
