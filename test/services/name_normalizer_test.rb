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

  test "differs_only_by_middle? allows middle names on one side only, in order" do
    assert NameNormalizer.differs_only_by_middle?("shamel ferebee", "shamel deshawn ferebee")
    assert NameNormalizer.differs_only_by_middle?("shamel deshawn ferebee", "shamel ferebee")
    assert NameNormalizer.differs_only_by_middle?("ana lucia ruiz", "ana maria lucia ruiz")
    assert NameNormalizer.differs_only_by_middle?("ana maria lucia ruiz", "ana lucia ruiz")

    assert_not NameNormalizer.differs_only_by_middle?("shamel ferebee", "shamel ferebee") # equal: the exact rule
    assert_not NameNormalizer.differs_only_by_middle?("ana lucia ruiz", "ana maria ruiz") # a middle name that differs
    assert_not NameNormalizer.differs_only_by_middle?("ana lucia maria ruiz", "ana maria lucia ruiz")
    assert_not NameNormalizer.differs_only_by_middle?("ana lucia maria ruiz", "ana maria jose lucia ruiz")
    assert_not NameNormalizer.differs_only_by_middle?("ana ruiz", "ana maria lopez")
    assert_not NameNormalizer.differs_only_by_middle?("maria ruiz", "ana maria ruiz")
    assert_not NameNormalizer.differs_only_by_middle?("ferebee", "shamel ferebee")
    assert_not NameNormalizer.differs_only_by_middle?(nil, "shamel ferebee")
  end

  test "close_spelling? is one letter slip in one long enough word" do
    assert NameNormalizer.close_spelling?("juan ortez", "juan ortiz") # changed
    assert NameNormalizer.close_spelling?("juan ortz", "juan ortiz") # dropped
    assert NameNormalizer.close_spelling?("shamel fereebee", "shamel ferebee") # added
    assert NameNormalizer.close_spelling?("jaun ortiz", "juan ortiz") # swapped, 4 letters

    assert_not NameNormalizer.close_spelling?("li chan", "li chen") # 4 letters: both real surnames
    assert_not NameNormalizer.close_spelling?("jon ortiz", "jan ortiz")
    assert_not NameNormalizer.close_spelling?("jaun ortis", "juan ortiz") # two words off
    assert_not NameNormalizer.close_spelling?("juan ortega", "juan ortiz")
    assert_not NameNormalizer.close_spelling?("juan ortiz", "juan ortiz")
    assert_not NameNormalizer.close_spelling?("juan carlos ortiz", "juan ortiz")
    assert_not NameNormalizer.close_spelling?("ortiz", "ortez")
  end

  test "each_word_within_one_edit? allows a letter off in every word" do
    assert NameNormalizer.each_word_within_one_edit?("jaun ortis", "juan ortiz")
    assert NameNormalizer.each_word_within_one_edit?("li chan", "li chen")
    assert_not NameNormalizer.each_word_within_one_edit?("juan ortiz", "juan ortiz")
    assert_not NameNormalizer.each_word_within_one_edit?("jose ortiz", "juan ortiz")
    assert_not NameNormalizer.each_word_within_one_edit?("juan ortiz", "juan c ortiz ruiz")
  end
end
