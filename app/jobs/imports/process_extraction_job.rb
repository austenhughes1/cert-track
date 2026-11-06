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
  # Phase 3b (step 6b): Imports::Splitter gives each item the QR codes on its own pages. The
  # issuer is matched (Imports::IssuerMatcher) from those QR links and the printed
  # verification_url, the model's certificate_issuer_code, then the printed issuer name.
  # proposed_verification_code is the model's, else the id in a matched issuer's QR link, else the
  # certificate number when the issuer looks certificates up by code: models often leave the code
  # blank when it is the printed number, and without one the issuer's site is never asked.
  # (Imports::IssuerMatcher.code_in_link); proposed_verification_url is that QR link, else the
  # printed address, else the matched issuer's link_template with the code. When the pages
  # carry several of the issuer's QR links (one page or photo with several people's cards), the
  # one with the certificate's code or number, else the one naming the holder, is used; none
  # when they can't be told apart. A printed address on another site than the matched issuer's
  # gives way to the issuer's own link for the code, unless it imitates an issuer's site: then
  # it is kept, so the check flags it. Verification::Run then checks the item with local rules
  # only, before Imports::Decider (which never auto-accepts a flagged item). When the matched
  # issuer's site can confirm the code (a network Verification::Checkers key) and automatic
  # checks are on, Verification::CheckJob asks it once this job's transaction has committed,
  # and the item waits for review: it isn't auto-accepted before the issuer's site has answered.
  # A person's Not found or Doesn't match that Imports::Reread kept goes back to needs a check
  # when this reading's issuer, code or link (for a mismatch also the person or dates) differ
  # from the ones they checked (Authenticity#reset_fake_for_new_reading!), before the check.
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
      @network_checks = []
      ImportItem.transaction do
        next unless ImportItem::PIPELINE_STATUSES.include?(ImportItem.where(id: item.id).lock.pick(:status))

        item.reload
        process(item)
      end

      @network_checks.each { |checked| Verification::CheckJob.perform_later(checked) }
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
            asking_issuer = check_authenticity(part.item)
            decide(part.item, issuer_check_pending: asking_issuer)
          end
        end
      end

      def propose(item, certificate)
        type = Imports::TypeMatcher.new(code: certificate["certificate_type_code"], name_as_printed: certificate["certificate_name_as_printed"]).call
        person = Imports::PersonMatcher.new(certificate["holder_name"]).call
        dates = Imports::DateRules.new(completed_on: date(certificate, "completed_on"), expires_on: date(certificate, "expires_on"),
          validity_months: certificate["validity_months"], no_expiration: certificate["no_expiration"], certificate_type: type.type).call

        item.update!(
          **issuer_proposal(item, certificate),
          holder_name_raw: text(certificate["holder_name"]),
          certificate_name_raw: text(certificate["certificate_name_as_printed"]),
          issuer_raw: text(certificate["issuer"]),
          proposed_certificate_number: text(certificate["certificate_number"]),
          confidence: confidence(certificate["confidence"]),
          matched_certificate_type: type.type, type_match: type.match, type_suggestions: type.suggestions,
          matched_crew_member: person.crew_member, person_match: person.match, person_suggestions: person.suggestions,
          proposed_completed_on: dates.completed_on, proposed_expires_on: dates.expires_on,
          proposed_expires_on_source: dates.expires_on_source,
          quality_flags: Imports::ImageQuality.flags(item, certificate, dates),
          error_message: dates.errors.join(" ").presence
        )
        item.reset_fake_for_new_reading! # Read again kept a person's fake result: is it about these details?
      end

      # Step 6b: the issuer match, then the verification code and link (see the class comment).
      # The item's barcodes are the QR codes on its own pages (Imports::Splitter).
      def issuer_proposal(item, certificate)
        qr_texts = Array(item.barcodes).filter_map { |barcode| text(barcode["text"], limit: nil) if barcode.is_a?(Hash) }
        printed_url = Certificate.normalize_verification_url(text(certificate["verification_url"], limit: nil))
        issuer = Imports::IssuerMatcher.new(code: text(certificate["certificate_issuer_code"]), name_as_printed: text(certificate["issuer"]),
          urls: [ *qr_texts, printed_url ].compact).call
        known = issuer.issuer if issuer.match == :matched
        code = text(certificate["verification_code"], limit: nil)
        qr_link = issuer_qr_link(qr_texts, known, codes: [ code, text(certificate["certificate_number"], limit: nil) ].compact,
          holder: text(certificate["holder_name"]))
        code ||= Imports::IssuerMatcher.code_in_link(known, qr_link)
        code ||= text(certificate["certificate_number"], limit: nil) if known&.verified_by_qr_or_code? || known&.verified_by_code_lookup?

        { matched_certificate_issuer: issuer.issuer, issuer_match: issuer.match, issuer_suggestions: issuer.suggestions,
          proposed_verification_code: code, proposed_verification_url: qr_link || verification_link(printed_url, known, code) }
      end

      # The QR link on the matched issuer's domain (see the class comment). codes: the model's
      # verification code and certificate number.
      def issuer_qr_link(qr_texts, known, codes:, holder:)
        links = qr_texts.filter_map { |qr_text| Certificate.normalize_verification_url(qr_text) if known&.owns_url?(qr_text) }.uniq
        return links.first if links.size <= 1

        by_code = links.select { |link| (found = Imports::IssuerMatcher.code_in_link(known, link)) && codes.any? { found.casecmp?(it) } }
        return by_code.first if by_code.one?

        by_holder = links.select do |link|
          Verification::NameMatch.compare_last_name(holder, Verification::QrLink.parse(link)&.holder&.last_name) == "match"
        end
        by_holder.first if by_holder.one?
      end

      # The printed address, or the matched issuer's own link for the code when the printed one is
      # on another site that doesn't imitate an issuer's (see the class comment).
      def verification_link(printed_url, known, code)
        own = known&.link_for(code)
        return printed_url || own if printed_url.nil? || own.nil? || known.owns_url?(printed_url)

        Verification::Lookalike.for_issuers.lookalike?(printed_url) ? printed_url : own
      end

      # Local rules only (no request to the issuer's site): a flagged item is never auto-accepted.
      # The issuer's site is asked after commit when the run held that back (Verification::Run trusts
      # only a matched issuer: a code sent to a merely suggested one could come back "not found" for a
      # real certificate, and flag it). Returns whether it will be asked; until it answers, the item
      # isn't auto-accepted (Imports::Decider's issuer_check_pending:).
      def check_authenticity(item)
        run = Verification::Run.new(item, network: false)
        run.call
        @network_checks << item if run.automatic_check_deferred?
        run.automatic_check_deferred?
      end

      def decide(item, issuer_check_pending:)
        return item.needs_review! unless Imports::Decider.new(item, issuer_check_pending:).call == :accept

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

      # Squished text, cut to limit (nil: never cut, for codes and links a cut would break).
      def text(value, limit: TEXT_LIMIT)
        return if value.is_a?(Hash) || value.is_a?(Array)

        text = value.to_s.squish.presence
        limit && text ? text.truncate(limit) : text
      end

      # 0..1, rounded down to 2 places so 0.849 never passes a 0.85 threshold. nil when not a number.
      def confidence(value)
        number = BigDecimal(value.to_s, exception: false) unless value.is_a?(Hash) || value.is_a?(Array) || value.nil?
        number&.clamp(0, 1)&.floor(2)
      end
  end
end
