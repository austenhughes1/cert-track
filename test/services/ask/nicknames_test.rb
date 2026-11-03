require "test_helper"

class Ask::NicknamesTest < ActiveSupport::TestCase
  test "nicknames expand to formal names" do
    assert_equal %w[robert], Ask::Nicknames.expand("bob")
    assert_equal %w[steven stephen], Ask::Nicknames.expand("steve")
    assert_equal %w[jesus], Ask::Nicknames.expand("chuy")
    assert_includes Ask::Nicknames.expand("beto"), "roberto"
    assert_includes Ask::Nicknames.expand("sam"), "samantha"
  end

  test "formal names expand to their nicknames" do
    assert_includes Ask::Nicknames.expand("robert"), "bob"
    assert_includes Ask::Nicknames.expand("roberto"), "beto"
    assert_includes Ask::Nicknames.expand("juan"), "juanito"
  end

  test "unknown names expand to nothing" do
    assert_empty Ask::Nicknames.expand("zebulon")
  end

  test "the map is lowercase ASCII, as tokens are" do
    Ask::Nicknames::MAP.each do |nickname, names|
      assert_match(/\A[a-z]+\z/, nickname)
      names.each { |name| assert_match(/\A[a-z]+\z/, name) }
    end
  end
end
