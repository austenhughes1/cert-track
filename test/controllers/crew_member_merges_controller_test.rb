require "test_helper"

class CrewMemberMergesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @juan = crew_members(:juan_ortiz)
    @li = crew_members(:li_chen)
  end

  test "viewers can't open or merge" do
    sign_in_as users(:viewer)

    get new_crew_member_merge_path(@li, into: @juan.id)
    assert_response :forbidden
    assert_no_difference -> { CrewMember.count } do
      post crew_member_merge_path(@li), params: { into: @juan.id }
    end
    assert_response :forbidden
  end

  test "new offers everyone else and, once chosen, shows what moves" do
    sign_in_as users(:manager)

    get new_crew_member_merge_path(@li)
    assert_response :success
    assert_select "select#into option[value='#{@juan.id}']"
    assert_select "select#into option[value='#{@li.id}']", count: 0
    assert_select "#merge_preview", count: 0

    get new_crew_member_merge_path(@li, into: @juan.id)
    assert_select "#merge_moves", text: /3 certificates move/
    assert_select "#merge_moves", text: /Both have a current/
    assert_select "#merge_moves", text: /Both are on/
    assert_select "a[href=?]", new_crew_member_merge_path(@juan, into: @li.id), text: /Keep Li Chen instead/
    assert_select "#merge_button"
  end

  test "new starts from the possible duplicate it was marked as" do
    sign_in_as users(:manager)
    @li.update!(possible_duplicate_of: @juan)

    get new_crew_member_merge_path(@li)
    assert_select "select#into option[selected][value='#{@juan.id}']"
    assert_select "#merge_preview"
  end

  test "create merges and goes to the kept record" do
    sign_in_as users(:manager)

    assert_difference -> { CrewMember.count }, -1 do
      post crew_member_merge_path(@li), params: { into: @juan.id }
    end
    assert_redirected_to crew_member_path(@juan)
    assert_match(/Merged Li Chen into Juan Ortiz: 3 certificates, 1 project and \d+ imported cards? moved/, flash[:notice])
    assert_not CrewMember.exists?(@li.id)
  end

  test "create without a record to keep goes back with the reason" do
    sign_in_as users(:manager)

    assert_no_difference -> { CrewMember.count } do
      post crew_member_merge_path(@li), params: { into: @li.id }
    end
    assert_redirected_to new_crew_member_merge_path(@li)
    assert_equal "Choose a different crew member to merge into.", flash[:alert]
  end
end
