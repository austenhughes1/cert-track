require "test_helper"

class Verification::NameMatchTest < ActiveSupport::TestCase
  def compare(holder, shown)
    Verification::NameMatch.compare(holder, shown)
  end

  test "the same name in any case, punctuation, accents or order matches" do
    [
      [ "Juan A. Ortiz", "JUAN ORTIZ" ],
      [ "Juan Ortiz", "ORTIZ, JUAN A." ],
      [ "Juan Ortiz", "Ortiz, Juan" ],
      [ "José O'Brien", "JOSE OBRIEN" ],
      [ "María García", "maria garcia" ],
      [ "Juan Ortiz Jr.", "Juan Ortiz" ],
      [ "Juan Antonio Ortiz", "Juan Ortiz" ]
    ].each do |holder, shown|
      assert_equal "match", compare(holder, shown), "#{holder} / #{shown}"
    end
  end

  test "a first initial matches the first name" do
    assert_equal "match", compare("Juan Ortiz", "J. Ortiz")
    assert_equal "match", compare("J Ortiz", "Juan Ortiz")
    assert_equal "match", compare("Juan Ortiz", "ORTIZ, J")
  end

  test "compound last names match on either part" do
    assert_equal "match", compare("Juan Ortiz-Ruiz", "Juan Ortiz")
    assert_equal "match", compare("Maria Garcia", "María García-López")
    assert_equal "match", compare("Maria Garcia Lopez", "Maria Lopez")
  end

  test "a different last name, first name or initial differs" do
    [
      [ "Juan Ortiz", "Juan Ortega" ],
      [ "Juan Ortiz", "Maria Ortiz" ],
      [ "Juan Ortiz", "M. Ortiz" ],
      [ "Juan Ortiz", "Li Chen" ],
      [ "Juan Ortiz", "Ortiz, Maria" ]
    ].each do |holder, shown|
      assert_equal "differs", compare(holder, shown), "#{holder} / #{shown}"
    end
  end

  test "any of the holder's names may match (preferred name, aliases)" do
    assert_equal "match", compare([ "Juan Ortiz", "Johnny Ortiz" ], "JOHNNY ORTIZ")
    assert_equal "differs", compare([ "Juan Ortiz", "Johnny Ortiz" ], "Jaime Ortiz")
  end

  test "nothing to compare is nil" do
    assert_nil compare("Juan Ortiz", nil)
    assert_nil compare("Juan Ortiz", "")
    assert_nil compare("Juan Ortiz", "Ortiz"), "a bare surname"
    assert_nil compare(nil, "Juan Ortiz")
    assert_nil compare([], "Juan Ortiz")
    assert_nil compare([ "", nil ], "Juan Ortiz")
  end

  test "compare_last_name compares the last name only" do
    assert_equal "match", Verification::NameMatch.compare_last_name("Juan A. Ortiz", "ORTIZ")
    assert_equal "match", Verification::NameMatch.compare_last_name("Juan Ortiz-Ruiz", "Ruiz")
    assert_equal "match", Verification::NameMatch.compare_last_name("Juan de la Cruz", "De La Cruz")
    assert_equal "differs", Verification::NameMatch.compare_last_name("Juan Ortiz", "Ortega")
    assert_nil Verification::NameMatch.compare_last_name("Juan Ortiz", nil)
    assert_nil Verification::NameMatch.compare_last_name(nil, "Ortiz")
  end
end
