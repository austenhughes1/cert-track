module Verification
  # Spots a web address that imitates a certificate issuer's site, a classic sign of a fake
  # certificate (docs/PLAN.md, Phase 3b, authenticity rule 1).
  #
  #   lookalike = Verification::Lookalike.for_issuers      # every issuer's domains
  #   lookalike.imitated_domain("redcross-verify.com")    # => "redcross.org"
  #   lookalike.imitated_domain("verify.360training.com") # => nil (the issuer's own site)
  #   lookalike.imitated_domain("example.com")            # => nil (unrelated)
  #   lookalike.known?("www.redcross.org")                # => true
  #   lookalike.imitated_domain("xn--redcrss-ejg.org")    # => "redcross.org" (punycode for "redcrоss.org")
  #
  # Hosts spelled with letters outside a-z (as text, Verification::QrLink.unreadable_host, or as
  # punycode) are compared folded to a-z (Verification::Homograph); one that folds to an issuer's
  # own domain is a lookalike too.
  #
  # suspicion says why a whole web address (a QR code's text, a printed or typed link) can't be
  # trusted, for Verification::Run's rule 1 and the authenticity panel:
  #
  #   lookalike.suspicion("https://redcross-verify.com/c/1")
  #   # => #<Suspicion host: "redcross-verify.com", looks_like: "redcross.org", disguised: false, lookalike_letters: false>
  #   lookalike.suspicion("https://www.redcross.org@verify-now.net/c/1")
  #   # => #<Suspicion host: "verify-now.net", looks_like: nil, disguised: true, ...>: text before an "@"
  #   #    makes it look like another site's address
  #   lookalike.suspicion("https://www.redcross.org/x") # => nil
  #
  # A host on an issuer's domain (any subdomain) is never a lookalike. Otherwise it is one when:
  #   - the host contains an issuer's distinctive name: a domain's name without its ending, when it
  #     has at least MIN_TOKEN_LENGTH letters and digits ("redcross", "360training", "clicksafety";
  #     "heart" and "nsc" are too common);
  #   - its domain has the same name with another ending ("heart.com" for heart.org); or
  #   - its domain is a small edit away from an issuer's (Ask::TextDistance, a swap counts as one
  #     edit): two edits for names of 6 or more characters ("redcros.org", "360trainning.com"), one
  #     for 4-5 ("hearts.org"), none for shorter ones, so usc.edu isn't taken for usf.edu.
  class Lookalike
    MIN_TOKEN_LENGTH = 6

    # disguised: the address hides its real host behind text and an "@". lookalike_letters: the
    # host imitates looks_like with letters from other alphabets (it can read the same on screen).
    Suspicion = Data.define(:host, :looks_like, :disguised, :lookalike_letters)

    # A Lookalike that knows every issuer's domains (inactive issuers' sites are still real).
    def self.for_issuers
      new(CertificateIssuer.pluck(:domains).flatten)
    end

    def initialize(domains)
      @domains = Array(domains).filter_map { |domain| CertificateIssuer.registrable_domain(domain) }.uniq
    end

    # Whether the URL's (or host's) domain is one of the known issuer domains.
    def known?(url_or_host)
      host = host_for(url_or_host)
      host.present? && @domains.include?(CertificateIssuer.domain_of_host(host))
    end

    # The issuer domain the URL's host imitates, or nil (an issuer's own site, an unrelated site,
    # or no web address at all).
    def imitated_domain(url_or_host)
      host = host_for(url_or_host)
      return if host.nil? || @domains.include?(CertificateIssuer.domain_of_host(host))

      folded = Homograph.fold(host)
      domain = CertificateIssuer.domain_of_host(folded)
      return if domain.nil?
      return domain if @domains.include?(domain) # an issuer's own name in look-alike letters

      compact_host = folded.delete("-")
      @domains.find { |known| imitates?(known, domain, compact_host) }
    end

    def lookalike?(url_or_host)
      imitated_domain(url_or_host).present?
    end

    # A Suspicion for a web address that imitates an issuer's site or is disguised, else nil (see above).
    def suspicion(text)
      link = QrLink.parse(text)
      host = link&.host || QrLink.unreadable_host(text)
      return if host.nil?

      imitated = imitated_domain(host)
      disguised = link&.hidden_host? || false
      return unless imitated || disguised

      Suspicion.new(host: host, looks_like: imitated, disguised: disguised,
        lookalike_letters: imitated.present? && Homograph.international?(host))
    end

    private
      # The host of a URL or bare host, in any letters; nil when there is none.
      def host_for(url_or_host)
        CertificateIssuer.host_of(url_or_host) || QrLink.unreadable_host(url_or_host) || unicode_host(url_or_host)
      end

      # A bare host written with letters outside a-z ("redcrоss.org"), as QrLink.unreadable_host returns it.
      def unicode_host(text)
        host = text.to_s.strip.downcase.delete_suffix(".").delete_prefix("www.")
        host if !host.ascii_only? && host.match?(/\A[\p{L}\p{N}.-]+\.\p{L}{2,}\z/)
      end

      def imitates?(known, domain, compact_host)
        known_name = name_of(known)
        return true if known_name.length >= MIN_TOKEN_LENGTH && compact_host.include?(known_name.delete("-"))
        return true if name_of(domain) == known_name

        allowed = allowed_edits(known_name)
        allowed.positive? && Ask::TextDistance.distance(domain, known) <= allowed
      end

      # "redcross.org" -> "redcross"; "example.co.uk" -> "example".
      def name_of(domain)
        domain.split(".").first
      end

      def allowed_edits(name)
        if name.length >= 6 then 2
        elsif name.length >= 4 then 1
        else 0
        end
      end
  end
end
