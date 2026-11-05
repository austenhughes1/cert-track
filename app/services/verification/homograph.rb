module Verification
  # Web addresses spelled with look-alike letters (docs/PLAN.md, Phase 3b, authenticity rule 1):
  # a Cyrillic "о" in "redcrоss.org", or the same host as punycode ("xn--redcrss-0ug.org"). URI
  # can't read the first, and the second contains no "redcross", so Verification::Lookalike
  # compares the folded host instead.
  #
  #   Verification::Homograph.fold("xn--redcrss-0ug.org")  # => "redcross.org"
  #   Verification::Homograph.fold("www.redcrоss.org")     # => "www.redcross.org" (Cyrillic о)
  #   Verification::Homograph.fold("ｒｅｄｃｒｏｓｓ.org")    # => "redcross.org" (full-width letters)
  #   Verification::Homograph.fold("redcross.org")         # => "redcross.org" (unchanged)
  #   Verification::Homograph.international?("xn--mnchen-3ya.de") # => true
  #
  # fold decodes punycode labels (RFC 3492), takes accents off (NFKD), and maps the Cyrillic,
  # Greek and Latin letters that look like a-z (CONFUSABLES) to them. Letters it doesn't know stay
  # as they are; Lookalike's edit distance still catches a host one or two such letters away.
  module Homograph
    PUNYCODE_PREFIX = "xn--".freeze
    CONFUSABLES = {
      # Cyrillic
      "а" => "a", "с" => "c", "ԁ" => "d", "е" => "e", "һ" => "h", "і" => "i", "ј" => "j",
      "к" => "k", "ӏ" => "l", "м" => "m", "п" => "n", "о" => "o", "р" => "p", "ԛ" => "q", "г" => "r",
      "ѕ" => "s", "т" => "t", "ц" => "u", "ѵ" => "v", "ԝ" => "w", "х" => "x", "у" => "y",
      # Greek
      "α" => "a", "β" => "b", "ϲ" => "c", "δ" => "d", "ε" => "e", "η" => "n", "ι" => "i", "κ" => "k",
      "ν" => "v", "ο" => "o", "ρ" => "p", "τ" => "t", "υ" => "u", "χ" => "x", "γ" => "y", "ω" => "w",
      # Latin letters without a decomposition, and other look-alikes
      "ı" => "i", "ɩ" => "i", "ł" => "l", "ø" => "o", "đ" => "d", "ħ" => "h", "ɑ" => "a", "ɡ" => "g",
      "ʀ" => "r", "ս" => "u", "ո" => "n", "ց" => "g", "օ" => "o", "ⅼ" => "l"
    }.freeze

    # RFC 3492 parameters.
    BASE = 36
    T_MIN = 1
    T_MAX = 26
    SKEW = 38
    DAMP = 700
    INITIAL_BIAS = 72
    INITIAL_N = 128
    MAX_LABEL_LENGTH = 63

    module_function

    # The host with punycode labels decoded, accents off and look-alike letters mapped to a-z,
    # lowercased. A label that isn't valid punycode is kept as written.
    def fold(host)
      host.to_s.downcase.split(".", -1).map { |label| fold_label(decode_label(label) || label) }.join(".")
    end

    # Whether the host is written with letters outside a-z, as text or as punycode.
    def international?(host)
      host = host.to_s
      !host.ascii_only? || host.downcase.split(".").any? { |label| label.start_with?(PUNYCODE_PREFIX) }
    end

    # The Unicode text of one punycode label ("xn--mnchen-3ya" -> "münchen"), or nil when the
    # label isn't punycode or can't be decoded.
    def decode_label(label)
      return unless label.start_with?(PUNYCODE_PREFIX) && label.length <= MAX_LABEL_LENGTH

      punycode_decode(label.delete_prefix(PUNYCODE_PREFIX))
    end

    def fold_label(label)
      label.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.each_char.map { |char| CONFUSABLES.fetch(char, char) }.join
    end

    # RFC 3492, section 6.2. nil for input that isn't valid punycode.
    def punycode_decode(input)
      return unless input.ascii_only?

      delimiter = input.rindex("-")
      output = delimiter ? input[0...delimiter].codepoints : []
      position = delimiter ? delimiter + 1 : 0
      code, bias, index = INITIAL_N, INITIAL_BIAS, 0

      while position < input.length
        old_index, weight, k = index, 1, BASE
        loop do
          return if position >= input.length

          digit = punycode_digit(input[position])
          position += 1
          return if digit.nil?

          index += digit * weight
          threshold = (k - bias).clamp(T_MIN, T_MAX)
          break if digit < threshold

          weight *= BASE - threshold
          k += BASE
        end
        bias = punycode_adapt(index - old_index, output.size + 1, old_index.zero?)
        code += index / (output.size + 1)
        index %= output.size + 1
        return if code > 0x10FFFF || code.between?(0xD800, 0xDFFF)

        output.insert(index, code)
        index += 1
      end
      output.pack("U*")
    end

    def punycode_digit(char)
      case char
      when "0".."9" then char.ord - 22
      when "a".."z" then char.ord - 97
      when "A".."Z" then char.ord - 65
      end
    end

    def punycode_adapt(delta, points, first)
      delta = first ? delta / DAMP : delta / 2
      delta += delta / points
      k = 0
      while delta > ((BASE - T_MIN) * T_MAX) / 2
        delta /= BASE - T_MIN
        k += BASE
      end
      k + (((BASE - T_MIN + 1) * delta) / (delta + SKEW))
    end
    private_class_method :fold_label, :punycode_decode, :punycode_digit, :punycode_adapt
  end
end
