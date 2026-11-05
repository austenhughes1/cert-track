module Verification
  # What one authenticity check found (docs/PLAN.md, Phase 3b).
  #
  #   status   :verified | :not_found | :mismatch | :suspicious | :needs_check | :cannot_verify | :unavailable
  #            (:unavailable = the check couldn't run; Verification::Run records it as needs_check with the note)
  #   method   "automatic:aha_ecards", "qr_details:qr_details_360training", "qr_link", "rules"
  #   note     plain words for the authenticity panel, never names, codes or dates
  #   details  { "issuer_status" => "Active", "compared" => { "holder" => "match", "completed_on" => "differs" } }
  #            which fields matched, never their values
  class Result < Data.define(:status, :method, :note, :details)
    STATUSES = %i[verified not_found mismatch suspicious needs_check cannot_verify unavailable].freeze

    def initialize(status:, method:, note: nil, details: {})
      raise ArgumentError, "unknown verification status #{status.inspect}" unless STATUSES.include?(status)

      super(status: status, method: method.to_s, note: note, details: details.to_h.deep_stringify_keys)
    end

    def unavailable? = status == :unavailable
  end
end
