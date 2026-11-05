module Verification
  # A verification link read from a QR code or printed on a certificate, taken apart.
  #
  #   link = Verification::QrLink.parse("https://www.redcross.org/take-a-class/qrcode?certnumber=ABC123")
  #   link.domain   # => "redcross.org"
  #   link.issuer   # => the active CertificateIssuer on that domain, or nil
  #   link.code     # => "ABC123"
  #   link.holder   # => nil (only 360training links carry the holder's details)
  #
  #   Verification::QrLink.parse("Not a link") # => nil
  #   Verification::QrLink.parse("2025.03.14") # => nil (a bare word must end in a letter top-level domain)
  #
  #   Verification::QrLink.unreadable_host("https://www.redcrоss.org/x") # => "redcrоss.org" (Cyrillic о):
  #     a web address URI can't read, because its host has letters outside a-z (Verification::Homograph)
  #
  # The code comes from the first of CODE_PARAMS in the query (any letter case); else from the
  # issuer's link_template when the link follows it; else from the last path segment after a
  # segment such as "verify" or "cert" (oshacardportal.com/portalapp/verify/<code>,
  # verifycco.org/cert/<code>).
  #
  # 360training's QR links carry the holder's name, course and issue date (s_fname, s_mname,
  # s_lname, course, issued as MM/DD/YYYY); holder returns them as a Holder.
  class QrLink
    CODE_PARAMS = %w[certnumber certificate_id enrollmentId cid code id certificateNumber].freeze
    PATH_CODE_AFTER = %w[verify verification validate validation cert certs certificate certificates credential credentials badge badges card].freeze
    MIN_PATH_CODE_LENGTH = 4
    # A bare word ("redcross.org/x") is a web address only when its host ends in a top-level domain
    # of letters: not "2025.03.14" or "AB12.3456" (Imports::Extraction::Normalizer::WEB_HOST).
    WEB_HOST = /\.[a-z]{2,}\z/
    SCHEME = %r{\Ahttps?://}i
    # A web address whose host may hold any letters: scheme (or a bare word), optional userinfo,
    # host, port, then a path, query or fragment.
    ANY_WEB_ADDRESS = %r{\A(?:https?://)?(?:[^\s/?#@]*@)?(?<host>[^\s/?#:@]+?)\.?(?::\d+)?(?:[/?#]\S*)?\z}i

    Holder = Data.define(:first_name, :middle_name, :last_name, :course, :issued) do
      def name
        [ first_name, middle_name, last_name ].compact_blank.join(" ")
      end

      # The issue date as a Date, or nil when missing or unreadable.
      def issued_on
        DateText.parse(issued)&.date
      end
    end

    attr_reader :url, :host, :domain

    class << self
      # A QrLink for a web address (bare "redcross.org/..." is read as https, http as https), or nil
      # for any other text. Text around a link ("Verify: https://...") is ignored.
      def parse(text)
        candidate, bare = candidate(text)
        url = Certificate.normalize_verification_url(candidate)
        return if url.nil? || (bare && !CertificateIssuer.host_of(url).match?(WEB_HOST))

        new(url, bare: bare)
      end

      # The host of an http(s):// address that parse can't read because the host has letters
      # outside a-z (lowercased, without "www."), or nil: for a link parse reads, and for text that
      # isn't such an address (a bare word with accents is more likely a name than a site).
      def unreadable_host(text)
        candidate, bare = candidate(text)
        return if candidate.nil? || bare || candidate.ascii_only? || parse(text)

        host = ANY_WEB_ADDRESS.match(candidate)&.[](:host)&.downcase&.delete_prefix("www.")
        host if host&.include?(".") && host.match?(/\.\p{L}{2,}\z/)
      end

      private
        # The word that holds the web address, and whether it was written without http(s)://.
        def candidate(text)
          words = text.to_s.split
          linked = words.find { |word| word.match?(SCHEME) }
          return [ linked, false ] if linked

          [ words.first, true ] if words.one?
        end
    end

    # bare: written without http(s)://.
    def initialize(url, bare: false)
      @url = url
      @uri = URI.parse(url)
      @host = CertificateIssuer.host_of(url)
      @domain = CertificateIssuer.registrable_domain(url)
      @bare = bare
    end

    # Written without http(s)://: a plain word that happens to be dotted, as likely as a web address.
    def bare?
      @bare
    end

    # The address puts other text before an "@", so it opens a site other than the one it seems
    # to name ("https://www.redcross.org@verify-now.net/" opens verify-now.net).
    def hidden_host?
      @uri.userinfo.present?
    end

    # The active issuer whose domains include this link's (memoized).
    def issuer
      return @issuer if defined?(@issuer)

      @issuer = CertificateIssuer.for_url(url)
    end

    def code
      query_code || template_code || path_code
    end

    def holder
      last_name = param("s_lname")
      return if last_name.blank?

      Holder.new(first_name: param("s_fname"), middle_name: param("s_mname"), last_name: last_name,
        course: param("course"), issued: param("issued"))
    end

    # The value of a query parameter, case-insensitive name, squished; nil when missing or blank.
    def param(name)
      key = params.keys.find { |candidate| candidate.casecmp?(name) }
      params[key].to_s.squish.presence if key
    end

    private
      def params
        @params ||= URI.decode_www_form(@uri.query.to_s).each_with_object({}) do |(key, value), all|
          all[key] ||= value
        end
      rescue ArgumentError
        @params = {}
      end

      def query_code
        CODE_PARAMS.lazy.filter_map { |name| param(name) }.first
      end

      # The {code} part of a link built from the issuer's link_template.
      def template_code
        template = issuer&.link_template
        return if template.blank?

        before, after = template.split(CertificateIssuer::CODE_PLACEHOLDER, 2)
        pattern = /\A#{Regexp.escape(strip_scheme(before))}([^\/?#&]+)#{Regexp.escape(after.to_s)}\z/i
        match = strip_scheme(url).match(pattern)
        URI.decode_www_form_component(match[1]).squish.presence if match
      rescue ArgumentError
        nil
      end

      def path_code
        segments = @uri.path.to_s.split("/").compact_blank
        return if segments.size < 2 || !PATH_CODE_AFTER.include?(segments[-2].downcase)

        code = URI.decode_www_form_component(segments.last).squish
        code if code.length >= MIN_PATH_CODE_LENGTH && code.match?(/\d/)
      rescue ArgumentError
        nil
      end

      def strip_scheme(text)
        text.sub(%r{\Ahttps?://(www\.)?}i, "")
      end
  end
end
