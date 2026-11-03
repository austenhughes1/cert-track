require "test_helper"

class Ask::TextDistanceTest < ActiveSupport::TestCase
  test "distance counts single-letter edits, a swap of neighbours as one" do
    assert_equal 0, Ask::TextDistance.distance("juan", "juan")
    assert_equal 1, Ask::TextDistance.distance("jaun", "juan")
    assert_equal 1, Ask::TextDistance.distance("ortis", "ortiz")
    assert_equal 1, Ask::TextDistance.distance("juan", "juana")
    assert_equal 3, Ask::TextDistance.distance("kitten", "sitting")
    assert_equal 4, Ask::TextDistance.distance("", "abcd")
  end

  test "similarity is relative to the longer word" do
    assert_in_delta 1.0, Ask::TextDistance.similarity("juan", "juan")
    assert_in_delta 0.75, Ask::TextDistance.similarity("jaun", "juan")
    assert_in_delta 0.8, Ask::TextDistance.similarity("ortis", "ortiz")
    assert_in_delta 1.0, Ask::TextDistance.similarity("", "")
  end
end
