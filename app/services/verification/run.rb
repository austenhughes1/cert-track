module Verification
  # Checks the authenticity of an import item or a certificate and records the result on it
  # (Authenticity#record_authenticity!), by the rules in docs/PLAN.md, Phase 3b:
  #
  #   1. suspicious     a QR code, or the record's own verification link, points to a site that looks
  #                     like an issuer's but isn't (Verification::Lookalike, look-alike letters and
  #                     punycode included), or is disguised ("https://www.redcross.org@verify-now.net/"
  #                     opens verify-now.net). A QR code to an unrelated site is noted and ignored; one
  #                     whose address has letters CertTrack can't read is noted and left for a person.
  #   2. QR details     the issuer's automatic_check is a local checker (qr_details_360training):
  #                     its result (mismatch, or needs_check: the QR code isn't the issuer's word).
  #                     Without such a QR code to compare, rules 3 to 5 decide.
  #   3. automatic      the issuer's automatic_check asks the issuer's site, when network is on and a
  #                     code is known: verified, mismatch, not_found, or unavailable (recorded as
  #                     needs_check, with the note saying why).
  #   4. needs_check    there is a code, a link or an issuer's QR code for a person to use (an issuer
  #                     with no registry is rule 5 instead).
  #   5. cannot_verify  the issuer's method is no_registry, or there is nothing to check with.
  #   6. A person's result (method "person") is left alone, and nil returned, unless force: true
  #      ("Check again"). With requested_at (when the page with the button was shown), force
  #      replaces only a result recorded by then: one a person records after that, while the job
  #      waits or runs included, stays. The result is written under a row lock after re-reading
  #      who checked last (a certificate is reloaded), so a person's result saved during a
  #      network check (up to 10 s) isn't overwritten either. Only a person's not_found or
  #      mismatch makes a certificate confirmed fake (Authenticity); a flagged result recorded
  #      here is only flagged for review.
  #   7. A person's not_found or mismatch whose details changed afterwards (method
  #      "details_changed", needs_check: Authenticity) is settled only by a person's result or a
  #      definite answer (verified, or flagged): the rules alone (needs_check, cannot_verify) or an
  #      issuer's site that couldn't be asked leave it as it is, so it stays on the list to check,
  #      forced or not. A definite answer keeps what the person had recorded (the reset's
  #      details, Authenticity::RESET_HISTORY_KEYS) and says so at the end of its note.
  #
  #   result = Verification::Run.new(item).call  # => a Verification::Result (status :unavailable
  #                                              #    when the site couldn't be asked), or nil when
  #                                              #    nothing was recorded (rules 6 and 7)
  #   Verification::Run.new(certificate, force: true, requested_at: clicked_at).call # "Check again"
  #
  # Import item: the issuer is matched_certificate_issuer only when issuer_match is matched (a
  # fuzzy-name suggestion is not trusted with an automatic check); proposed_verification_code/url,
  # barcodes, proposed dates. The holder is the person the certificate will be for: the crew member
  # a reviewer picked, else holder_name_raw and the exactly matched member's names.
  # Certificate: certificate_issuer, verification_code/url, the crew member's names, its dates;
  # barcodes: the QR codes read from its files ([{ "page" =>, "text" => }], none when not given).
  # The code is the record's, else the one in its link on the issuer's domain, else the one in its
  # QR codes on that domain when they all carry the same one (a page with several people's cards
  # carries several). An expiry CertTrack worked out (from the type or a printed period) is not
  # the certificate's own, so it is never compared with the issuer's.
  #
  # network: false (VERIFICATION_AUTO_CHECKS off, or a caller that mustn't wait) skips rule 3.
  # When it is only the caller that mustn't wait (automatic checks are on), automatic_check_deferred?
  # says so after call, and the caller queues Verification::CheckJob (Imports::ProcessExtractionJob).
  # When the issuer's site was asked moments ago (HttpClient::Throttled), Verification::CheckJob is
  # scheduled to try again (attempt: counts the tries, up to CheckJob::BUSY_ATTEMPTS).
  class Run
    Subject = Data.define(:issuer, :code, :url, :barcodes, :holder_names, :completed_on, :expires_on)

    # What was last recorded on the record, read again under its row lock by write_result.
    Stored = Data.define(:method, :checked_at, :details)
    STORED_COLUMNS = %w[authenticity_method authenticity_checked_at authenticity_details].freeze
    private_constant :Stored, :STORED_COLUMNS

    RULES_METHOD = "rules".freeze
    QR_LINK_METHOD = "qr_link".freeze
    LINK_METHOD = "verification_link".freeze

    # What is wrong with a suspicious address, after "The QR code" or "This link":
    # "points to redcross-verify.com, which looks like redcross.org but isn't".
    def self.suspicion_words(suspicion)
      if suspicion.disguised
        "is disguised: it opens #{suspicion.host}, not the site its address seems to name"
      elsif suspicion.lookalike_letters
        "points to a web address spelled with look-alike letters to pass for #{suspicion.looks_like}"
      else
        "points to #{suspicion.host}, which looks like #{suspicion.looks_like} but isn't"
      end
    end

    def initialize(record, network: Config.auto_checks?, force: false, requested_at: nil, barcodes: nil, attempt: 0)
      unless record.is_a?(ImportItem) || record.is_a?(Certificate)
        raise ArgumentError, "Verification::Run checks an ImportItem or a Certificate, not #{record.class.name}"
      end

      @record = record
      @network = network
      @force = force
      @requested_at = requested_at
      @barcodes = barcodes
      @attempt = attempt
    end

    def call
      return if persons_result_stays?(@record.authenticity_method, @record.authenticity_checked_at)

      result = suspicious || qr_details || automatic || by_rules
      result = result.with(note: [ result.note, retry_sentence(result), unrelated_qr_sentence ].compact.join(" "),
        details: result.details.merge(unrelated_qr_details))
      outcome = write_result(result)
      return if outcome.nil?

      schedule_retry if retry?(result)
      result if outcome == :written
    end

    # After call: whether rule 3 would have asked the issuer's site but network: false held it back
    # while automatic checks are on, so Verification::CheckJob should ask it.
    def automatic_check_deferred?
      @automatic_skipped == :deferred
    end

    private
      # Rule 6, for the method and time of the last check.
      def persons_result_stays?(method, checked_at)
        return false unless method == Authenticity::PERSON_METHOD
        return true unless @force

        @requested_at.present? && checked_at.present? && checked_at > @requested_at
      end

      # Writes the result unless a person's result was saved while the rules ran (rule 6): what was
      # last recorded is read again under a row lock. A certificate is reloaded under that lock, its
      # crew member locked first as Certificate does when it saves: a result that replaces a
      # confirmed fake one re-ranks which certificate is current, and CheckJob's copy is seconds old
      # by now (moved, re-dated, outranked or deleted meanwhile). An import item is not reloaded,
      # only those columns read, so what the caller holds in memory (files attached in this
      # transaction) is kept. Returns :written, :kept (a reset left as it is, rule 7) or nil (a
      # person's result stays, rule 6, or the record was deleted meanwhile).
      def write_result(result)
        @record.class.transaction(requires_new: true) do
          stored = lock_stored_check
          reset = stored&.method == Authenticity::DETAILS_CHANGED_METHOD
          if stored.nil? || persons_result_stays?(stored.method, stored.checked_at)
            nil
          elsif reset && !definite?(result)
            :kept
          else
            history = reset ? stored.details.to_h.slice(*Authenticity::RESET_HISTORY_KEYS) : {}
            write_every_check_column
            @record.record_authenticity!(status: result.unavailable? ? :needs_check : result.status, method: result.method,
              note: [ result.note, Authenticity.reset_history_sentence(history) ].compact.join(" "), details: result.details.merge(history))
            :written
          end
        end
      end

      # An ImportItem isn't reloaded (the pipeline may hold unsaved changes), so its copy of the check
      # can be stale: a column whose new value equals that copy would be left out of the UPDATE, keeping
      # what someone saved meanwhile. A certificate was just reloaded under lock.
      def write_every_check_column
        return if @record.is_a?(Certificate)

        @record.authenticity_attributes.each_key { |column| @record.public_send("#{column}_will_change!") }
      end

      # Rule 7: an answer that settles a reset (a person's fake result whose details changed).
      def definite?(result)
        result.status == :verified || Authenticity::FLAGGED_STATUSES.include?(result.status.to_s)
      end

      # The Stored check under a row lock, or nil when the record is gone.
      def lock_stored_check
        if @record.is_a?(Certificate)
          member_id = Certificate.where(id: @record.id).pick(:crew_member_id)
          return if member_id.nil?

          CrewMember.where(id: member_id).lock.pluck(:id)
          @record.reload(lock: true)
          Stored.new(*@record.attributes.values_at(*STORED_COLUMNS))
        else
          row = ImportItem.where(id: @record.id).lock.pick(*STORED_COLUMNS)
          Stored.new(*row) if row
        end
      rescue ActiveRecord::RecordNotFound
        nil
      end

      # Rule 1: the QR codes first, then the record's own link.
      def suspicious
        [ *qr_texts.map { |text| [ :qr, text ] }, [ :link, subject.url ] ].each do |source, text|
          result = suspicious_address(source, text)
          return result if result
        end
        nil
      end

      def suspicious_address(source, text)
        suspicion = lookalike.suspicion(text)
        return if suspicion.nil?

        what, key, method = source == :qr ? [ "The QR code", "qr_host", QR_LINK_METHOD ] : [ "The verification link", "link_host", LINK_METHOD ]
        details = { key => suspicion.host, "looks_like" => suspicion.looks_like, "disguised" => (true if suspicion.disguised),
          "lookalike_letters" => (true if suspicion.lookalike_letters) }.compact
        Result.new(status: :suspicious, method: method, note: "#{what} #{self.class.suspicion_words(suspicion)}.", details: details)
      end

      # Rule 2. The local checker returns nil when there is nothing local to compare.
      def qr_details
        key = issuer&.automatic_check
        checker(key).call if key.present? && !Checkers.network?(key)
      end

      # Rule 3. Sets @automatic_skipped when the issuer has a network check that can't run.
      def automatic
        key = issuer&.automatic_check
        return unless key.present? && Checkers.network?(key)

        @automatic_skipped = if code.nil? then :no_code
        elsif !issuer.owns_url?(Checkers.for(key)::ENDPOINT) then :other_site
        elsif !@network then Config.auto_checks? ? :deferred : :off
        end
        checker(key).call unless @automatic_skipped
      end

      # Rules 4 and 5.
      def by_rules
        if issuer&.verified_by_no_registry?
          rules_result(:cannot_verify, "#{issuer.name} keeps no public registry, so this certificate can't be checked with the issuer.")
        elsif code || subject.url.present? || qr_links.any? { |link| lookalike.known?(link.host) } || unreadable_qr_hosts.any?
          rules_result(:needs_check, [ skipped_sentence, needs_check_sentence ].compact.join(" "))
        else
          rules_result(:cannot_verify, "There's no verification code, link or QR code to check this certificate with.")
        end
      end

      def rules_result(status, note)
        Result.new(status: status, method: RULES_METHOD, note: note)
      end

      def needs_check_sentence
        if issuer.nil?
          "Open the verification link, or look the code up on the issuer's own site."
        elsif issuer.verified_by_contact?
          "Contact #{issuer.name} to check this certificate (see the issuer's verification notes)."
        else
          "Open the verification page to check this certificate with #{issuer.name}."
        end
      end

      def skipped_sentence
        case @automatic_skipped
        when :off then "Automatic checks are switched off."
        when :deferred then "CertTrack will ask #{issuer.name}'s site to confirm it in a moment."
        when :no_code then "#{issuer.name} can be checked automatically, but there's no verification code."
        when :other_site then "#{issuer.name}'s automatic check isn't on the issuer's own site, so it wasn't run."
        end
      end

      def checker(key)
        Checkers.for(key).new(code: code, verification_url: subject.url, holder_name: subject.holder_names,
          completed_on: subject.completed_on, expires_on: subject.expires_on, barcodes: subject.barcodes)
      end

      def issuer
        subject.issuer
      end

      # The record's code, else the one in its link on the issuer's domain, else the one its QR codes
      # on that domain agree on (see the class comment).
      def code
        return @code if defined?(@code)

        own = ->(link) { link.code if link && issuer&.owns_url?(link.url) }
        qr_codes = qr_links.filter_map { |link| own.call(link) }.uniq
        @code = subject.code.to_s.squish.presence || own.call(QrLink.parse(subject.url)) || (qr_codes.first if qr_codes.one?)
      end

      def subject
        @subject ||= @record.is_a?(ImportItem) ? item_subject(@record) : certificate_subject(@record)
      end

      # A picked person is the reviewer's word that the card is theirs, so the printed name (perhaps
      # someone else's) doesn't count; an exact match is the printed name already.
      def item_subject(item)
        holder_names = if item.person_picked? && item.matched_crew_member
          member_names(item.matched_crew_member)
        else
          [ item.holder_name_raw, *member_names((item.matched_crew_member if item.person_matched?)) ]
        end
        Subject.new(issuer: (item.matched_certificate_issuer if item.issuer_matched?), code: item.proposed_verification_code,
          url: item.proposed_verification_url, barcodes: Array(@barcodes || item.barcodes), holder_names: holder_names.compact_blank.uniq,
          completed_on: item.proposed_completed_on,
          expires_on: (item.proposed_expires_on unless item.proposed_expiry_computed? || item.proposed_expiry_none? || item.proposed_expiry_printed_period?))
      end

      def certificate_subject(certificate)
        Subject.new(issuer: certificate.certificate_issuer, code: certificate.verification_code,
          url: certificate.verification_url, barcodes: Array(@barcodes), holder_names: member_names(certificate.crew_member),
          completed_on: certificate.completed_on, expires_on: (certificate.expires_on unless certificate.expiry_computed? || certificate.expiry_printed_period?))
      end

      def member_names(member)
        return [] if member.nil?

        [ member.full_name, member.display_name, *member.name_aliases ].compact_blank.uniq
      end

      def qr_texts
        @qr_texts ||= subject.barcodes.filter_map { |barcode| barcode.is_a?(Hash) ? (barcode["text"] || barcode[:text]) : barcode }
      end

      # The QR codes that are web links.
      def qr_links
        @qr_links ||= qr_texts.filter_map { |text| QrLink.parse(text) }
      end

      def lookalike
        @lookalike ||= Lookalike.for_issuers
      end

      # QR codes to sites that are neither an issuer's nor imitating one: noted, otherwise ignored.
      # Only those written as links (http/https): a dotted word ("juan.ortiz") isn't named in a note.
      def unrelated_qr_hosts
        @unrelated_qr_hosts ||= qr_links.reject { |link| link.bare? || link.hidden_host? }.map(&:host).uniq
          .reject { |host| lookalike.known?(host) || lookalike.lookalike?(host) }
      end

      # QR codes with a web address in letters CertTrack can't read, that don't imitate an issuer's:
      # left for a person to look at (never dropped silently).
      def unreadable_qr_hosts
        @unreadable_qr_hosts ||= qr_texts.filter_map { |text| QrLink.unreadable_host(text) }.uniq.reject { |host| lookalike.lookalike?(host) }
      end

      def unrelated_qr_sentence
        sentences = []
        hosts = unrelated_qr_hosts
        if hosts.one?
          sentences << "A QR code points to #{hosts.first}, which isn't an issuer's site, so it was ignored."
        elsif hosts.any?
          sentences << "QR codes point to #{hosts.to_sentence}, which aren't issuers' sites, so they were ignored."
        end
        if unreadable_qr_hosts.any?
          one = unreadable_qr_hosts.one?
          sentences << "#{one ? "A QR code holds a web address" : "QR codes hold web addresses"} spelled with letters " \
            "other than a to z (#{unreadable_qr_hosts.to_sentence}); look at #{one ? "it" : "them"} before trusting #{one ? "it" : "them"}."
        end
        sentences.join(" ").presence
      end

      def unrelated_qr_details
        { "other_qr_hosts" => unrelated_qr_hosts.presence, "unreadable_qr_hosts" => unreadable_qr_hosts.presence }.compact
      end

      def busy?(result)
        result.unavailable? && result.details["unavailable"] == "busy"
      end

      def retry?(result)
        busy?(result) && @attempt < CheckJob::BUSY_ATTEMPTS
      end

      def retry_sentence(result)
        "CertTrack will try again in a moment." if retry?(result)
      end

      def schedule_retry
        CheckJob.set(wait: CheckJob.busy_wait(@attempt)).perform_later(@record, attempt: @attempt + 1)
      end
  end
end
