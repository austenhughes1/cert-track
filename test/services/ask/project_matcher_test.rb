require "test_helper"

class Ask::ProjectMatcherTest < ActiveSupport::TestCase
  setup do
    Project.create!(name: "Golden Water Tank Repaint", code: "GW-12", status: :active)
  end

  test "suggestions resemble the phrase by a name word or a code" do
    tower = projects(:tower_2417)

    assert_equal [ tower ], Ask::ProjectMatcher.suggestions("towr")
    assert_equal [ tower ], Ask::ProjectMatcher.suggestions("Upgrade")
    assert_equal [ tower ], Ask::ProjectMatcher.suggestions("2471")
    assert_equal [ projects(:closed_2390) ], Ask::ProjectMatcher.suggestions("2391")
    assert_equal [ "GW-12" ], Ask::ProjectMatcher.suggestions("gw12").map(&:code)
  end

  test "an unrelated phrase gets no suggestions, never every active project" do
    %w[recently blah 9999 quarter].push("so far", "?").each do |phrase|
      assert_empty Ask::ProjectMatcher.suggestions(phrase), phrase
    end
  end
end
