require "test_helper"

class NameNormalizerTest < ActiveSupport::TestCase
  test "drops middle initials and punctuation" do
    assert_equal "juan ortiz", NameNormalizer.normalize("Juan A. Ortiz")
    assert_equal "juan ortiz", NameNormalizer.normalize("Juan A B Ortiz")
    assert_equal "juan ortiz", NameNormalizer.normalize("  JUAN   ORTIZ ")
  end

  test "keeps a leading or trailing initial, so initials stay distinct" do
    assert_equal "j ortiz", NameNormalizer.normalize("J. Ortiz")
    assert_equal "j smith", NameNormalizer.normalize("J. A. Smith")
    assert_equal "juan o", NameNormalizer.normalize("Juan O.")
    assert_not_equal NameNormalizer.normalize("J. Smith"), NameNormalizer.normalize("K. Smith")
    assert_not_equal NameNormalizer.normalize("J. Smith"), NameNormalizer.normalize("Smith")
  end

  test "transliterates accents" do
    assert_equal "jose pena", NameNormalizer.normalize("José Peña")
    assert_equal "maria garcia lopez", NameNormalizer.normalize("María García-López")
  end

  test "removes apostrophes without splitting the name" do
    assert_equal "shea obrien", NameNormalizer.normalize("Shea O'Brien")
    assert_equal "shea obrien", NameNormalizer.normalize("Shea O’Brien")
  end

  test "keeps two-letter names and joined initials" do
    assert_equal "li chen", NameNormalizer.normalize("Li Chen")
    assert_equal "aj smith", NameNormalizer.normalize("A.J. Smith")
  end

  test "reads Last, First as First Last" do
    assert_equal "juan ortiz", NameNormalizer.normalize("Ortiz, Juan")
    assert_equal "juan ortiz", NameNormalizer.normalize("ORTIZ, JUAN A")
    assert_equal "j smith", NameNormalizer.normalize("Smith, J.")
    assert_equal "jose obrien", NameNormalizer.normalize("O'Brien, José")
  end

  test "leaves a suffix after the comma, and other comma counts, in place" do
    assert_equal "juan ortiz jr", NameNormalizer.normalize("Juan Ortiz, Jr.")
    assert_equal "juan ortiz", NameNormalizer.normalize("Juan Ortiz,")
    assert_equal "ortiz juan jr", NameNormalizer.normalize("Ortiz, Juan, Jr")
    assert_equal "juan", NameNormalizer.normalize(", Juan")
  end

  test "treats other punctuation as separators" do
    assert_equal "juan ortiz", NameNormalizer.normalize("Juan/Ortiz")
  end

  test "matchable? needs at least two tokens" do
    assert NameNormalizer.matchable?("j smith")
    assert_not NameNormalizer.matchable?("smith")
    assert_not NameNormalizer.matchable?("")
    assert_not NameNormalizer.matchable?(nil)
  end

  test "handles nil and blank" do
    assert_equal "", NameNormalizer.normalize(nil)
    assert_equal "", NameNormalizer.normalize("  . ")
  end
end
