require "test_helper"

class CrewMembers::DuplicateFinderTest < ActiveSupport::TestCase
  def find(name, except: nil)
    CrewMembers::DuplicateFinder.new(name, except:).call
  end

  test "finds the closest member by score, or by every word a letter off" do
    assert_equal crew_members(:juan_ortiz), find("Juan Ortizes")
    assert_equal crew_members(:juan_ortiz), find("Jaun Ortis")
    assert_equal crew_members(:li_chen), find("Li Chan")
  end

  test "nobody close, and never the member itself" do
    assert_nil find("Robert Example")
    assert_nil find("Juan Ortiz", except: crew_members(:juan_ortiz))
    assert_nil find("")
  end
end
