module Imports
  # Steps 5 to 9 of the import pipeline, after Imports::AiExtractJob stored the model's JSON
  # in item.extraction: split, dedupe, match type and person, apply the date rules, then
  # auto-accept or queue for review. Finally the batch's check_completion!.
  #
  # No certificates -> the item goes to review with NO_CERTIFICATE in error_message (the
  # non-certificate pages stay in extraction): a free model can miss a real card, so a person
  # confirms with Reject ("Not a certificate") or fills the fields in and accepts. It is
  # never rejected unseen, which would also make every later upload of the file a duplicate.
  # Otherwise Imports::Splitter gives each certificate its own item. An item whose sha256 and
  # page range already belong to an earlier item outside this file's own items is marked
  # duplicate of it. The rest get their proposals: holder_name_raw, certificate_name_raw,
  # issuer_raw, proposed_* (Imports::DateRules problems go to error_message for the reviewer;
  # a date the normalizer could not read, kept under "unreadable", is passed on so it is
  # reported rather than replaced by a computed expiry), confidence (rounded down to 2
  # places), and the type and person matches with suggestions. Imports::Decider then picks
  # Imports::Accept (auto) or needs_review; an auto-accept the Certificate model refuses goes
  # to review with the reason in error_message.
  #
  # Runs in one transaction under a row lock on the item, so a retry or a second copy of the
  # job never splits twice: an item that is no longer pending or extracting is left alone.
  # Errors are retried; after the last attempt the item is failed with the error message. A
  # SystemStackError (a parser recursing on a hostile file) is not a StandardError and would
  # fail the same way again, so it fails the item at once.
  class ProcessExtractionJob < ApplicationJob
    queue_as :imports # the import worker (config/queue.yml); see Imports::ExpandJob

    NO_CERTIFICATE = "The AI found no certificate in this file. Reject it if that is right; " \
                     "if it is a certificate, fill in the fields and accept it.".freeze
    TEXT_LIMIT = 255

    discard_on ActiveJob::DeserializationError
    retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
      job.fail_item(job.arguments.first, error)
    end
    rescue_from SystemStackError do |error|
      Rails.error.report(error, handled: true, context: { import_item_id: arguments.first&.id })
      fail_item(arguments.first, error)
    end

    def perform(item)
      ImportItem.transaction do
        next unless ImportItem::PIPELINE_STATUSES.include?(ImportItem.where(id: item.id).lock.pick(:status))

        item.reload
        process(item)
      end

      item.import_batch.check_completion!
    end

    # Called once the retries are used up. Only an item still in the pipeline is failed: one
    # that was processed (the error came from check_completion!) keeps its outcome.
    def fail_item(item, error)
      item = ImportItem.find_by(id: item.id)
      return unless item && ImportItem::PIPELINE_STATUSES.include?(item.status)

      item.update!(status: :failed, error_message: "Could not process the AI extraction: #{error.class.name}: #{error.message}".truncate(1_000))
      item.import_batch.check_completion!
    end

    private
      def process(item)
        extraction = item.extraction
        unless extraction.is_a?(Hash)
          item.update!(status: :failed, error_message: "There is no AI extraction to process.")
          return
        end

        certificates = Array(extraction.deep_stringify_keys["certificates"]).select { |certificate| certificate.is_a?(Hash) }
        if certificates.empty?
          item.update!(status: :needs_review, error_message: NO_CERTIFICATE)
          return
        end

        parts = Imports::Splitter.new(item).call(certificates)
        family_ids = parts.map { |part| part.item.id }
        parts.each do |part|
          original = ImportItem.original_for(part.item.sha256, part.item.page_range)
          if original && family_ids.exclude?(original.id)
            part.item.mark_duplicate_of!(original)
          else
            propose(part.item, part.certificate)
            decide(part.item)
          end
        end
      end

      def propose(item, certificate)
        type = Imports::TypeMatcher.new(code: certificate["certificate_type_code"], name_as_printed: certificate["certificate_name_as_printed"]).call
        person = Imports::PersonMatcher.new(certificate["holder_name"]).call
        dates = Imports::DateRules.new(completed_on: date(certificate, "completed_on"), expires_on: date(certificate, "expires_on"),
          certificate_type: type.type).call

        item.update!(
          holder_name_raw: text(certificate["holder_name"]),
          certificate_name_raw: text(certificate["certificate_name_as_printed"]),
          issuer_raw: text(certificate["issuer"]),
          proposed_certificate_number: text(certificate["certificate_number"]),
          confidence: confidence(certificate["confidence"]),
          matched_certificate_type: type.type, type_match: type.match, type_suggestions: type.suggestions,
          matched_crew_member: person.crew_member, person_match: person.match, person_suggestions: person.suggestions,
          proposed_completed_on: dates.completed_on, proposed_expires_on: dates.expires_on,
          proposed_expires_on_source: dates.expires_on_source,
          error_message: dates.errors.join(" ").presence
        )
      end

      def decide(item)
        return item.needs_review! unless Imports::Decider.new(item).call == :accept

        Imports::Accept.new(item, user: nil, auto: true).call
      rescue ActiveRecord::RecordInvalid => error
        item.update!(status: :needs_review, certificate: nil, reviewed_at: nil,
          error_message: "Auto-accept was refused: #{error.record.errors.full_messages.to_sentence.presence || error.message}")
      end

      # The ISO date, or the text the normalizer could not read as one, so Imports::DateRules
      # reports it (and never computes an expiry in place of an unreadable printed one).
      def date(certificate, field)
        unreadable = certificate["unreadable"]
        certificate[field].presence || (unreadable[field] if unreadable.is_a?(Hash))
      end

      def text(value)
        value.to_s.squish.truncate(TEXT_LIMIT).presence unless value.is_a?(Hash) || value.is_a?(Array)
      end

      # 0..1, rounded down to 2 places so 0.849 never passes a 0.85 threshold. nil when not a number.
      def confidence(value)
        number = BigDecimal(value.to_s, exception: false) unless value.is_a?(Hash) || value.is_a?(Array) || value.nil?
        number&.clamp(0, 1)&.floor(2)
      end
  end
end
