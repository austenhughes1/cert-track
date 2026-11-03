module Ask
  # Edit distance for short name tokens. Trigrams miss swapped letters ("jaun" shares
  # almost none with "juan"), so the person matcher also scores tokens by how few
  # single-letter edits (insert, delete, substitute, swap neighbours) turn one into the other.
  module TextDistance
    module_function

    # 1.0 for equal strings, falling toward 0.0 as edits grow relative to the longer one.
    def similarity(first, second)
      return 1.0 if first == second

      longest = [ first.length, second.length ].max
      return 0.0 if longest.zero?

      1.0 - distance(first, second).fdiv(longest)
    end

    # Optimal string alignment distance (Damerau-Levenshtein without repeated edits).
    def distance(first, second)
      a = first.chars
      b = second.chars
      rows = Array.new(a.size + 1) { |i| Array.new(b.size + 1) { |j| i.zero? ? j : (j.zero? ? i : 0) } }

      (1..a.size).each do |i|
        (1..b.size).each do |j|
          cost = a[i - 1] == b[j - 1] ? 0 : 1
          rows[i][j] = [ rows[i - 1][j] + 1, rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost ].min
          if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]
            rows[i][j] = [ rows[i][j], rows[i - 2][j - 2] + 1 ].min
          end
        end
      end
      rows[a.size][b.size]
    end
  end
end
