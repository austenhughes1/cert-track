module Imports
  module Extraction
    # JSON Schema of the model output contract (docs/PLAN.md, "Model output contract"), sent as
    # structured output to models that support it. Ranges (confidence 0..1, pages within the
    # file) are not expressed here because not every provider supports numeric constraints;
    # Imports::Extraction::Normalizer enforces them.
    #
    # Phase 3b: certificate_issuer_code (a code from the issuer list, like certificate_type_code),
    # verification_code and verification_url (only as printed: QR codes are read locally, not by the model).
    module Schema
      NULLABLE_STRING = { type: %w[string null] }.freeze
      FIELDS = %w[holder_name certificate_type_code certificate_name_as_printed issuer certificate_issuer_code
        certificate_number verification_code verification_url completed_on expires_on notes].freeze

      CERTIFICATE = {
        type: "object",
        properties: {
          pages: { type: "array", items: { type: "integer" } },
          holder_name: NULLABLE_STRING,
          certificate_type_code: NULLABLE_STRING,
          certificate_name_as_printed: NULLABLE_STRING,
          issuer: NULLABLE_STRING,
          certificate_issuer_code: NULLABLE_STRING,
          certificate_number: NULLABLE_STRING,
          verification_code: NULLABLE_STRING,
          verification_url: NULLABLE_STRING,
          completed_on: { type: %w[string null], description: "YYYY-MM-DD" },
          expires_on: { type: %w[string null], description: "YYYY-MM-DD, printed expiration only" },
          confidence: { type: "number" },
          notes: NULLABLE_STRING
        },
        required: %w[pages holder_name certificate_type_code certificate_name_as_printed issuer certificate_issuer_code
          certificate_number verification_code verification_url completed_on expires_on confidence notes],
        additionalProperties: false
      }.freeze

      JSON_SCHEMA = {
        name: "certificate_extraction",
        schema: {
          type: "object",
          properties: {
            certificates: { type: "array", items: CERTIFICATE },
            non_certificate_pages: { type: "array", items: { type: "integer" } }
          },
          required: %w[certificates non_certificate_pages],
          additionalProperties: false
        }
      }.freeze

      # The contract shape as a one-line example for the system prompt.
      EXAMPLE = {
        certificates: [ {
          pages: [ 1 ], holder_name: "Juan A. Ortiz", certificate_type_code: "OSHA30",
          certificate_name_as_printed: "OSHA 30-Hour Construction Industry Outreach Training",
          issuer: "Example Safety Training LLC", certificate_issuer_code: nil, certificate_number: "30-1234567",
          verification_code: "30-1234567", verification_url: "examplesafety.com/verify",
          completed_on: "2025-03-14", expires_on: nil, confidence: 0.92, notes: "No expiration printed"
        } ],
        non_certificate_pages: []
      }.to_json.freeze
    end
  end
end
