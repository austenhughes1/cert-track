# Bulk import intake (docs/PLAN.md, "Bulk import pipeline", step 1) and batch progress.
# Files arrive by Active Storage direct upload; create checks what was dropped, makes an
# ImportBatch and hands it to Imports::ExpandJob. Editors only: uploads and the per-item
# results carry personal data.
class ImportsController < ApplicationController
  require_role :editor

  RECENT_LIMIT = 20
  ITEMS_LIMIT = 500
  # What the drop zone takes, by extension; browsers label zips and HEIC photos inconsistently.
  EXTENSIONS = %w[pdf jpg jpeg png heic heif webp zip].freeze
  # A tampered or unknown signed id, or a blob whose direct upload never finished (the row
  # exists but the bytes don't, so identifying it fails).
  UNREADABLE_UPLOAD_ERRORS = [
    ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound, ActiveStorage::FileNotFoundError
  ].freeze

  # The index's AI line: provider, whether it is configured (problems lists what to set), today's
  # (UTC) use of the daily allocation, and how many items are parked until the 00:05 UTC reset.
  AiStatus = Data.define(:provider, :ready, :problems, :used, :budget, :exhausted, :waiting_count, :resumes_at)

  def index
    load_index
  end

  def create
    blobs = find_uploads(upload_signed_ids)
    @upload_errors = upload_errors(blobs)

    if @upload_errors.empty?
      batch = ImportBatch.create!(uploaded_by: Current.user, status: :receiving, uploads: blobs)
      Imports::ExpandJob.perform_later(batch)
      redirect_to import_path(batch), notice: "Uploaded #{helpers.pluralize(blobs.size, "file")}. Reading them now; this page updates as it goes."
    else
      @carried_over = carry_over(blobs)
      load_index
      render :index, status: :unprocessable_entity
    end
  end

  def show
    @batch = ImportBatch.includes(:uploaded_by).find(params.expect(:id))
    @progress = @batch.progress
    @items = @batch.import_items.order(:id).limit(ITEMS_LIMIT)
      .includes(:matched_crew_member, :matched_certificate_type, :duplicate_of, :certificate)
      .with_attached_file # "Read again" (Imports::Reread.allowed?) checks the file
      .to_a
    @reread_context = Imports::Reread.context_for(@items.select { |item| item.rejected? || item.failed? })
  end

  private
    def load_index
      @batches = ImportBatch.recent.includes(:uploaded_by).limit(RECENT_LIMIT).to_a
      ImportBatch.preload_progress(@batches)
      @review_count = ImportItem.needs_review.count
      @ai_status = ai_status
    end

    def ai_status
      waiting = ImportItem.waiting_for_budget
      provider = Ai::Config.provider
      limited = Ai::Budget.limited?(provider)
      AiStatus.new(
        provider: provider,
        ready: Ai::Config.ready?(provider),
        problems: Ai::Config.problems(provider),
        used: Ai::Budget.used_today(provider),
        budget: (Ai::Config.daily_budget if limited),
        exhausted: Ai::Budget.exhausted?(provider),
        waiting_count: waiting.count,
        resumes_at: waiting.minimum(:next_attempt_at)
      )
    rescue Ai::ConfigurationError => error
      AiStatus.new(provider: nil, ready: false, problems: [ error.message ], used: 0, budget: nil, exhausted: false,
        waiting_count: waiting.count, resumes_at: waiting.minimum(:next_attempt_at))
    end

    # Signed blob ids from the direct-upload field (plus any carried over from a failed
    # submit). The field's hidden "" input arrives as a blank.
    def upload_signed_ids
      params.expect(import: [ uploads: [] ]).fetch(:uploads, []).compact_blank.uniq
    rescue ActionController::ParameterMissing
      []
    end

    # Blobs for the signed ids; nil for any that is tampered with, gone or never finished
    # uploading. Identifying reads the first bytes (attaching would do it anyway), so a blob
    # whose PUT failed is caught here instead of raising inside ImportBatch.create!.
    def find_uploads(signed_ids)
      signed_ids.map do |signed_id|
        ActiveStorage::Blob.find_signed!(signed_id).tap(&:identify_without_saving)
      rescue *UNREADABLE_UPLOAD_ERRORS
        nil
      end
    end

    def upload_errors(blobs)
      return [ "Choose at least one file or zip to import." ] if blobs.empty?

      readable = blobs.compact
      errors = []
      errors << "Some files didn't finish uploading. Choose them again." if readable.size < blobs.size

      unsupported = readable.reject { |blob| supported_upload?(blob) }
      if unsupported.any?
        errors << "#{name_list(unsupported)} #{unsupported.one? ? "isn't" : "aren't"} a PDF, JPG, PNG, HEIC, WEBP or zip file."
      end
      if readable.size > Imports::Config.max_entries
        errors << "That's #{helpers.number_with_delimiter(readable.size)} files; a batch holds at most " \
                  "#{helpers.number_with_delimiter(Imports::Config.max_entries)}. Split them into smaller batches."
      end
      if (total = readable.sum(&:byte_size)) > Imports::Config.max_batch_bytes
        errors << "These files add up to #{helpers.number_to_human_size(total)}; a batch can be at most " \
                  "#{helpers.number_to_human_size(Imports::Config.max_batch_bytes)}. Split them into smaller batches."
      end
      errors
    end

    # The browser's content type or the extension must be one we read. Imports::ExpandJob
    # checks the real bytes later, so a mislabelled file still ends up rejected, not imported.
    def supported_upload?(blob)
      Imports::Config.upload_content_types.include?(blob.content_type) ||
        EXTENSIONS.include?(blob.filename.extension_without_delimiter.to_s.downcase)
    end

    # Uploads that would be fine on their own, offered again after a failed submit so a big
    # drop isn't uploaded twice. None when they are too many or too big together.
    def carry_over(blobs)
      usable = blobs.compact.select { |blob| supported_upload?(blob) }
      return [] if usable.sum(&:byte_size) > Imports::Config.max_batch_bytes || usable.size > Imports::Config.max_entries

      usable
    end

    def name_list(blobs, limit: 5)
      names = blobs.first(limit).map { |blob| blob.filename.to_s }
      names << "#{blobs.size - limit} more" if blobs.size > limit
      names.to_sentence
    end
end
