# Canonical form of a person's name for exact matching across spellings:
#   NameNormalizer.normalize("Juan A. Ortiz") # => "juan ortiz"
#   NameNormalizer.normalize("J. Ortiz")      # => "j ortiz"
#   NameNormalizer.normalize("ORTIZ, JUAN A") # => "juan ortiz"
#   NameNormalizer.normalize("O'Brien, José") # => "jose obrien"
# Reads "Last, First" (exactly one comma, not before a suffix such as Jr) as
# "First Last". Downcases, transliterates accents, removes apostrophes and periods,
# turns other punctuation into spaces and squishes whitespace. Single-letter tokens
# are dropped only between the first and last token (middle initials): a leading
# initial is kept, so "J. Smith" and "K. Smith" stay different people.
module NameNormalizer
  SUFFIXES = %w[jr sr ii iii iv].freeze
  # Fewer tokens than this (a bare surname, a lone initial) is never an exact match.
  MIN_MATCH_TOKENS = 2

  module_function

  def normalize(name)
    tokens = tokenize(first_name_first(name.to_s))
    last = tokens.size - 1
    tokens.reject.with_index { |token, index| token.length == 1 && index.positive? && index < last }.join(" ")
  end

  # True when a normalized name has enough tokens to identify a person on its own.
  def matchable?(normalized)
    normalized.to_s.split.size >= MIN_MATCH_TOKENS
  end

  def tokenize(text)
    ActiveSupport::Inflector.transliterate(text.delete("'’`."), "").downcase.gsub(/[^a-z0-9]+/, " ").split
  end

  def first_name_first(text)
    last, first, *rest = text.split(",")
    return text if rest.any? || first.nil?

    first_tokens = tokenize(first)
    return text if first_tokens.empty? || tokenize(last).empty? || first_tokens.all? { |token| SUFFIXES.include?(token) }

    "#{first} #{last}"
  end
  private_class_method :tokenize, :first_name_first
end
