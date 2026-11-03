module Imports
  # Import pipeline settings. Only AUTO_ACCEPT_ENABLED comes from the environment; the
  # limits and thresholds are the values PLAN.md fixes ("Bulk import pipeline").
  #
  #   Imports::Config.max_entries                    # => 2000
  #   Imports::Config.with(max_entries: 3) { ... }   # tests: override values for the block
  module Config
    LIMITS = {
      max_batch_bytes: 500.megabytes,       # everything dropped in one batch
      max_entries: 2_000,                   # files across a batch's zips (zip-bomb guard)
      max_uncompressed_bytes: 2.gigabytes,  # bytes read out of a batch's zips (zip-bomb guard)
      max_zip_depth: 2,                     # zips nested inside an uploaded zip
      auto_accept_confidence: 0.85,
      person_suggest_threshold: 0.6,
      person_margin: 0.15,                  # best candidate must beat the runner-up by this
      type_suggest_threshold: 0.45,
      ocr_min_chars: 40                     # fewer on a PDF page means it is a scan
    }.freeze

    SUPPORTED_CONTENT_TYPES = %w[application/pdf image/jpeg image/png image/heic image/heif image/webp].freeze
    ZIP_CONTENT_TYPES = %w[application/zip application/x-zip-compressed application/x-zip].freeze

    OVERRIDES_KEY = :imports_config_overrides
    private_constant :OVERRIDES_KEY

    class << self
      LIMITS.each_key do |name|
        define_method(name) { overrides.fetch(name) { LIMITS.fetch(name) } }
      end

      # Off until the owner trusts the import output (PLAN.md, step 9).
      def auto_accept_enabled?
        overrides.fetch(:auto_accept_enabled) { ENV["AUTO_ACCEPT_ENABLED"] == "true" } == true
      end

      # Content types a certificate file may have: PDF, JPEG, PNG, HEIC/HEIF, WEBP.
      def supported_content_types
        SUPPORTED_CONTENT_TYPES
      end

      def zip_content_types
        ZIP_CONTENT_TYPES
      end

      # Everything the Imports drop zone takes: certificate files and zips.
      def upload_content_types
        SUPPORTED_CONTENT_TYPES + ZIP_CONTENT_TYPES
      end

      def supported?(content_type)
        SUPPORTED_CONTENT_TYPES.include?(content_type.to_s)
      end

      def zip?(content_type)
        ZIP_CONTENT_TYPES.include?(content_type.to_s)
      end

      # Runs the block with some values replaced (any LIMITS key, or auto_accept_enabled:),
      # for this thread or fiber only. Meant for tests.
      def with(**values)
        unknown = values.keys - LIMITS.keys - [ :auto_accept_enabled ]
        raise ArgumentError, "unknown Imports::Config settings: #{unknown.join(", ")}" if unknown.any?

        previous = overrides
        ActiveSupport::IsolatedExecutionState[OVERRIDES_KEY] = previous.merge(values)
        begin
          yield
        ensure
          ActiveSupport::IsolatedExecutionState[OVERRIDES_KEY] = previous
        end
      end

      private
        def overrides
          ActiveSupport::IsolatedExecutionState[OVERRIDES_KEY] || {}
        end
    end
  end
end
