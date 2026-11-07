require "test_helper"

# A crew's phones: older ones are let in, and every screen is reachable from the menu.
class MobileAccessTest < ActionDispatch::IntegrationTest
  OLD_IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6 Mobile/15E148 Safari/604.1".freeze

  test "an older phone gets the sign-in page, not a refusal" do
    get new_session_path, headers: { "User-Agent" => OLD_IPHONE }

    assert_response :success
    assert_select "input[name=email_address]"
  end

  test "the phone menu holds every link the wide navigation has, and sign out" do
    sign_in_as users(:admin)

    get root_path

    wide = css_select("#nav_links a").map { it["href"] }
    assert_includes wide, imports_path
    assert_equal wide, css_select("#nav_menu a").map { it["href"] }
    assert_select "#nav_menu form[action=?]", session_path
    assert_select "nav.bg-gray-800 #nav_links.hidden"
  end

  test "the menu shows a viewer only what a viewer may open" do
    sign_in_as users(:viewer)

    get root_path

    hrefs = css_select("#nav_menu a").map { it["href"] }
    assert_not_includes hrefs, imports_path
    assert_not_includes hrefs, users_path
  end
end
