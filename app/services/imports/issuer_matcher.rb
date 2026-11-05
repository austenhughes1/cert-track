module Imports
  # Matches a certificate's issuer against the issuer list (docs/PLAN.md, step 6b).
  #
  #   result = Imports::IssuerMatcher.new(code: "REDCROSS", name_as_printed: "American Red Cross",
  #     urls: ["https://www.redcross.org/take-a-class/qrcode?certnumber=..."]).call
  #   result.issuer      # => the CertificateIssuer (the match, or the top suggestion), or nil
  #   result.match       # => :matched | :suggested | :unmatched
  #   result.suggestions # => [{ "id" => 1, "name" => "American Red Cross", "similarity" => 1.0 }, ...]
  #   result.source      # => :domain | :code | :name | nil
  #
  # In order: a URL (a QR code's text or the printed verification link) whose host is on an
  # active issuer's domains is :matched (source :domain), whatever code the model gave; when URLs
  # point to several issuers, the one the code names wins, else the first URL's. Else a code
  # that names an active issuer (case-insensitive) is :matched (:code). Else the printed name is
  # fuzzy-matched (pg_trgm) against active issuer names and aliases; a score of
  # CertificateIssuer::FUZZY_THRESHOLD (0.45) or more is :suggested (:name), never :matched. A
  # code that names an inactive issuer is only a suggestion (:code), listed after any active
  # candidates with "note" => "inactive issuer". Suggestions are best first, at most
  # MAX_SUGGESTIONS, like Imports::TypeMatcher's.
  #
  #   Imports::IssuerMatcher.code_in_link(issuer, url) # => "TEST123" (see below), or nil
  class IssuerMatcher
    Result = Data.define(:issuer, :match, :suggestions, :source)

    MAX_SUGGESTIONS = 5
    INACTIVE_NOTE = "inactive issuer".freeze
    # Query parameters an issuer's QR link carries its certificate id in, in order of preference
    # (Red Cross certnumber, National OSHA Foundation certificate_id, 360training enrollmentId).
    CODE_PARAMETERS = %w[certnumber certificate_id enrollmentid cid code id].freeze
    CODE_LIMIT = 80
    GARBLED = "\uFFFD".freeze # what URI decoding puts in place of bytes that aren't UTF-8
    SCHEME = %r{\A[a-z][a-z0-9+.-]*://}i

    class << self
      # The verification code inside one of issuer's links: the first CODE_PARAMETERS query
      # parameter with a value (names compared case-insensitively), else the part of the link
      # that stands for {code} in the issuer's link_template ("oshacardportal.com/portalapp/verify/<code>").
      # nil when neither is there, or the value is too long or garbled to be a code.
      def code_in_link(issuer, url)
        return if issuer.nil? || url.blank?

        code = (query_code(url) || template_code(issuer.link_template, url)).to_s.dup.force_encoding(Encoding::UTF_8)
        return if !code.valid_encoding? || code.include?(GARBLED) # bad %-escapes

        code = code.squish
        code if code.present? && code.length <= CODE_LIMIT
      end

      private
        def query_code(url)
          query = URI.parse(url.to_s.strip).query
          return if query.blank?

          params = URI.decode_www_form(query).each_with_object({}) { |(name, value), found| found[name.downcase] ||= value.presence }
          params.values_at(*CODE_PARAMETERS).compact.first
        rescue URI::InvalidURIError, ArgumentError
          nil
        end

        def template_code(template, url)
          return unless template.to_s.include?(CertificateIssuer::CODE_PLACEHOLDER)

          pattern = Regexp.escape(bare(template)).sub(Regexp.escape(CertificateIssuer::CODE_PLACEHOLDER), "([^/?#&]+)")
          code = bare(url)[/\A#{pattern}(?:[\/?#&]|\z)/i, 1]
          URI.decode_www_form_component(code) if code
        rescue ArgumentError
          nil
        end

        # "redcross.org/x" for "https://www.redcross.org/x".
        def bare(url)
          url.to_s.strip.sub(SCHEME, "").sub(/\Awww\./i, "")
        end
    end

    def initialize(code:, name_as_printed:, urls: [])
      @code = code.to_s.strip.presence
      @name_as_printed = name_as_printed.to_s.squish.presence
      @urls = Array(urls).filter_map { |url| url.to_s.strip.presence }
    end

    def call
      by_code = CertificateIssuer.find_by_code(@code) if @code
      fuzzy = fuzzy_candidates

      by_domain = domain_issuers
      if by_domain.any?
        issuer = by_domain.find { |candidate| candidate.id == by_code&.id } || by_domain.first
        return matched(issuer, fuzzy, source: :domain)
      end
      return matched(by_code, fuzzy, source: :code) if by_code&.active?

      candidates = fuzzy.map { |issuer, score| [ issuer, entry(issuer, score) ] }
      candidates << [ by_code, entry(by_code, 1.0, note: INACTIVE_NOTE) ] if by_code
      candidates = candidates.first(MAX_SUGGESTIONS)

      if candidates.empty?
        Result.new(issuer: nil, match: :unmatched, suggestions: [], source: nil)
      else
        source = fuzzy.any? ? :name : :code
        Result.new(issuer: candidates.first.first, match: :suggested, suggestions: candidates.map(&:last), source:)
      end
    end

    private
      # Active issuers that own one of the URLs, in URL order.
      def domain_issuers
        @urls.filter_map { |url| CertificateIssuer.for_url(url) }.uniq(&:id)
      end

      def matched(issuer, fuzzy, source:)
        others = fuzzy.reject { |candidate, _| candidate.id == issuer.id }
        suggestions = [ entry(issuer, 1.0) ] + others.first(MAX_SUGGESTIONS - 1).map { |candidate, score| entry(candidate, score) }
        Result.new(issuer:, match: :matched, suggestions:, source:)
      end

      def fuzzy_candidates
        return [] unless @name_as_printed

        CertificateIssuer.active.fuzzy_match(@name_as_printed)
      end

      def entry(issuer, similarity, note: nil)
        { "id" => issuer.id, "name" => issuer.name, "similarity" => similarity.to_f.round(3), "note" => note }.compact
      end
  end
end
