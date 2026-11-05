module Verification
  # Whether the name an issuer (or a QR link) shows is the certificate holder's.
  #
  #   Verification::NameMatch.compare("Juan A. Ortiz", "ORTIZ, JUAN")  # => "match"
  #   Verification::NameMatch.compare("Juan Ortiz", "J. Ortiz")         # => "match" (first initial)
  #   Verification::NameMatch.compare("Juan Ortiz", "Maria Ortiz")      # => "differs"
  #   Verification::NameMatch.compare([ "Juan Ortiz", "Johnny Ortiz" ], "Johnny Ortiz") # => "match"
  #   Verification::NameMatch.compare("Juan Ortiz", nil)                # => nil (nothing to compare)
  #
  # Names are read by NameNormalizer (case, punctuation, accents and "Last, First" order don't
  # matter). The same last name and the same first name, or a first initial matching it, is a match.
  # Compound last names count when one name's last name is among the other's ("Juan Ortiz-Ruiz"
  # and "Juan Ortiz"). holder may be several names the person goes by (preferred name, aliases):
  # any one matching is enough.
  module NameMatch
    Parts = Data.define(:first, :surnames)

    module_function

    # "match" / "differs", or nil when either side has no first and last name to compare.
    def compare(holder, shown)
      shown_parts = parts(shown)
      holder_parts = Array(holder).filter_map { |name| parts(name) }
      return if shown_parts.nil? || holder_parts.empty?

      holder_parts.any? { |candidate| same_person?(candidate, shown_parts) } ? "match" : "differs"
    end

    # "match" / "differs" for a last name alone (a QR link's s_lname), or nil when either is missing.
    def compare_last_name(holder, last_name)
      shown = tokens(last_name)
      holder_parts = Array(holder).filter_map { |name| parts(name) }
      return if shown.empty? || holder_parts.empty?

      holder_parts.any? { |candidate| same_surname?(candidate.surnames, shown) } ? "match" : "differs"
    end

    def parts(name)
      words = tokens(name)
      Parts.new(first: words.first, surnames: words.drop(1)) if words.size >= 2
    end

    # Normalized words without suffixes ("Jr", "III").
    def tokens(name)
      NameNormalizer.normalize(name.to_s).split - NameNormalizer::SUFFIXES
    end

    def same_person?(holder, shown)
      same_surname?(holder.surnames, shown.surnames) && same_first_name?(holder.first, shown.first)
    end

    def same_surname?(holder, shown)
      holder.last == shown.last || holder.include?(shown.last) || shown.include?(holder.last)
    end

    def same_first_name?(holder, shown)
      return true if holder == shown

      (holder.length == 1 && shown.start_with?(holder)) || (shown.length == 1 && holder.start_with?(shown))
    end
    private_class_method :parts, :tokens, :same_person?, :same_surname?, :same_first_name?
  end
end
