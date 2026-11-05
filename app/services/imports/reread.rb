module Imports
  # An editor's "Read again": sends an import item back through the pipeline, e.g. after a
  # wrong rejection, a "no certificate found", a failure, or after switching AI_PROVIDER
  # (say to anthropic for a backlog run).
  #
  #   Imports::Reread.allowed?(item)                           # => true or false, for the button
  #   item = Imports::Reread.new(item, user: Current.user).call # => the item, reloaded: pending, its job enqueued
  #   # or raises Imports::Reread::NotAllowed; the message is meant for the reviewer
  #
  #   context = Imports::Reread.context_for(items)              # a page of rows: two queries, not two per row
  #   Imports::Reread.allowed?(item, context:)
  #
  # Allowed for needs_review, rejected and failed items that are a whole uploaded file whose
  # file is still attached. Refused: accepted items (their certificate stays as it is, and
  # holds the file now), duplicates (the original is the one to read again, unless it was
  # accepted), items still being read, items with no file (refused when the batch was
  # unpacked, or failed more than 30 days ago: ImportItem.purge_stale_files!), a failed item
  # whose file was uploaded again later (that copy is the one kept), items from a PDF that
  # held several certificates (a split-off part, or the file's own item once others were split
  # from it), and an item whose file was cut down to its own pages. Those no longer have the
  # whole upload to read (Imports::Splitter replaced it with their pages), and reading a part
  # on its own would renumber its pages.
  #
  # The item's AI results and review are cleared (extraction, proposals, matches,
  # suggestions, confidence, error and rejection reason, skip, parking, attempts, reviewer,
  # page range; Phase 3b: issuer match, verification code and link, and the authenticity
  # check, a person's Verified or Can't be verified too, since it was of the old reading) and
  # it goes back to pending with
  # Imports::ExtractTextJob, which reuses extracted_text when it is still there (else OCR runs
  # again). A PDF item's text is cleared too (it has a page range), and its QR codes with it:
  # Imports::Splitter cuts both down to the pages the AI found even when it has to keep the
  # whole file (combine_pdf couldn't cut it), and the AI would then never see the other pages
  # again. ai_units_used keeps counting: the new read adds to
  # it. No other item, certificate or duplicate link is touched. The batch goes back to
  # processing and finishes again through check_completion!, but no second summary email is
  # sent (summary_sent_at was set the first time).
  #
  # A person's Not found or Doesn't match (confirmed fake) stays: it is the only way a
  # certificate is ever left out (owner, Nov 4, 2026), so reading the same file again must not
  # undo it. It keeps the digests of the details it was about (Authenticity): when the new
  # reading gives the same ones, the pipeline's check leaves it alone (Verification::Run, rule
  # 6); when they differ, nobody checked those, so Imports::ProcessExtractionJob turns it back
  # into needs a check. Either way Imports::Decider keeps the item for review, where the panel
  # shows it until someone checks it again.
  #
  # The item's row is locked while it is checked and reset, so a double click enqueues once.
  # A context is only for showing the button: call always checks everything again.
  class Reread
    class NotAllowed < StandardError; end

    REREADABLE_STATUSES = %w[needs_review rejected failed].freeze
    # Kept for a person's confirmed fake (see the class comment).
    AUTHENTICITY_RESET = {
      authenticity_status: :unchecked, authenticity_checked_at: nil, authenticity_checked_by_id: nil,
      authenticity_method: nil, authenticity_note: nil, authenticity_details: {}
    }.freeze
    RESET_ATTRIBUTES = {
      status: :pending, extraction: nil, provider: nil, page_range: nil, confidence: nil,
      holder_name_raw: nil, certificate_name_raw: nil, issuer_raw: nil, proposed_certificate_number: nil,
      proposed_completed_on: nil, proposed_expires_on: nil, proposed_expires_on_source: nil,
      matched_crew_member_id: nil, person_match: :unmatched, person_suggestions: [],
      matched_certificate_type_id: nil, type_match: :unmatched, type_suggestions: [],
      matched_certificate_issuer_id: nil, issuer_match: :unmatched, issuer_suggestions: [],
      proposed_verification_code: nil, proposed_verification_url: nil, **AUTHENTICITY_RESET,
      error_message: nil, rejection_reason: nil, skipped_at: nil, next_attempt_at: nil, attempts: 0,
      reviewed_by_id: nil, reviewed_at: nil
    }.freeze

    # What refusal needs to know about other items, looked up for a set of items at once (the
    # batch page shows up to 500 and refreshes every 3 s while it is live): which of them have
    # parts split from them, and the original of each failed one's file. An item it wasn't
    # looked up for is asked about on its own.
    class Context
      def initialize(items)
        items = Array(items).select { |item| item&.persisted? && REREADABLE_STATUSES.include?(item.status) }
        @ids = items.to_set(&:id)
        @with_parts = @ids.empty? ? Set.new : ImportItem.where(source_item_id: @ids.to_a).distinct.pluck(:source_item_id).to_set
        @digests = items.select(&:failed?).filter_map(&:sha256).to_set
        @originals = ImportItem.original_files_for(@digests.to_a)
      end

      def split_items?(item)
        @ids.include?(item.id) ? @with_parts.include?(item.id) : item.split_items.exists?
      end

      # ImportItem.original_file_for(item.sha256).
      def original_file_for(item)
        @digests.include?(item.sha256) ? @originals[item.sha256] : ImportItem.original_file_for(item.sha256)
      end
    end

    class << self
      # items: the rows a page may show the button on, for allowed?/refusal's context:.
      def context_for(items)
        Context.new(items)
      end

      def allowed?(item, context: nil)
        refusal(item, context:).nil?
      end

      # Why item can't be read again (a sentence for the reviewer), or nil when it can.
      def refusal(item, context: nil)
        return "This item no longer exists." unless item&.persisted?
        return status_refusal(item) unless REREADABLE_STATUSES.include?(item.status)
        return no_file_refusal(item) unless item.file.attached?

        context ||= Context.new([])
        return several_certificates_refusal(item) if item.source_item_id.present? || context.split_items?(item)
        return cut_down_refusal(item) if cut_down?(item)

        newer_copy_refusal(item, context) if item.failed?
      end

      private
        def status_refusal(item)
          case item.status
          when "accepted" then "Accepted items can't be read again."
          when "duplicate"
            original = item.duplicate_of
            where = original ? " (#{original.filename || "the earlier upload"}, batch ##{original.import_batch_id})" : ""
            if original&.accepted?
              "This is a duplicate of an earlier upload#{where}, which is already a certificate."
            else
              "This is a duplicate of an earlier upload: read the original#{where} again instead."
            end
          else "This item is already being read."
          end
        end

        # A failed item's file is deleted 30 days after it failed (ImportItem.purge_stale_files!).
        # Uploading it again makes a new item, since a failed item is never the original.
        def no_file_refusal(item)
          return "This item has no file to read again." unless item.failed?

          "This item has no file to read again (a failed item's file is deleted after 30 days). Upload the file again instead."
        end

        # The item's file was cut down to its own pages ("<name> p2-3.pdf"): a PDF with one
        # certificate and other pages. (A part, and its file's item, are refused before this.)
        # Compared as Active Storage filenames: filename.to_s turns "\", ":", "%" and the like in
        # a zip entry's name into "-" and strips spaces at the ends, so the name has to be too.
        def cut_down?(item)
          item.page_range.present? &&
            item.file.filename == ActiveStorage::Filename.new(Imports::Splitter.split_filename(item.original_filename.to_s, item.page_range))
        end

        # A failed file doesn't count as the original, so uploading it again made a new item
        # rather than a duplicate. That copy is the one kept. (Any other item is its file's
        # original: a later upload of it is a duplicate.)
        def newer_copy_refusal(item, context)
          newer = context.original_file_for(item)
          return unless newer && newer.id != item.id

          "This file was uploaded again later (batch ##{newer.import_batch_id}): read that copy again instead."
        end

        def several_certificates_refusal(item)
          "This item was cut from a PDF that held more than one certificate, so it can't be read again on its own. #{split_next_step(item)}"
        end

        def cut_down_refusal(item)
          pages = item.pages.one? ? "page" : "pages"
          "This item's file was cut down to the #{pages} its certificate is on (#{pages} #{item.page_range} of the uploaded " \
            "PDF), so it can't be read again on its own. #{split_next_step(item)}"
        end

        def split_next_step(item)
          item.needs_review? ? "Fill in its fields by hand instead." : "Upload those pages as a new file to read them again."
        end
    end

    def initialize(item, user:)
      @item = item
      @user = user
    end

    def call
      ImportItem.transaction do
        lock_item!
        reason = self.class.refusal(@item)
        raise NotAllowed, reason if reason

        @item.update!(reset_attributes)
      end

      Imports::ExtractTextJob.perform_later(@item)
      @item.import_batch.check_completion!
      Rails.logger.info("[imports] import item #{@item.id} sent to be read again by user #{@user&.id.inspect}")
      @item.reload
    end

    private
      # Imports::Splitter gives every PDF item it reads a page range, and may have cut its text
      # and QR codes down to those pages: the file is read again so the AI sees every page.
      # A person's confirmed fake stays (see the class comment).
      def reset_attributes
        attributes = @item.page_range.present? ? RESET_ATTRIBUTES.merge(extracted_text: nil, barcodes: nil) : RESET_ATTRIBUTES
        @item.authenticity_confirmed_fake? ? attributes.except(*AUTHENTICITY_RESET.keys) : attributes
      end

      # Reloads the item under a row lock: a second click waits here, then sees it pending.
      def lock_item!
        @item.reload(lock: true)
      rescue ActiveRecord::RecordNotFound
        raise NotAllowed, "This item no longer exists."
      end
  end
end
