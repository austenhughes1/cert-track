require "test_helper"

class CrewRoleTest < ActiveSupport::TestCase
  test "name is required and unique case-insensitively" do
    assert_not CrewRole.new(name: " ").valid?
    duplicate = CrewRole.new(name: "  foreman ")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end

  test "normalizes whitespace" do
    assert_equal "Rigger Lead", CrewRole.create!(name: "  Rigger   Lead ").name
  end

  test "cannot be destroyed while in use" do
    role = crew_roles(:climber)
    assert_not role.destroy
    assert role.errors[:base].any?
    assert CrewRole.exists?(role.id)
  end

  test "unused roles can be destroyed" do
    assert CrewRole.create!(name: "Driver").destroy
  end

  test "ordered by name" do
    assert_equal %w[Climber Foreman Laborer Operator], CrewRole.ordered.pluck(:name)
  end
end
