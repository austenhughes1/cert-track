require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = users(:manager) }

  test "new renders the sign-in card" do
    get new_session_path

    assert_response :success
    assert_select "title", "Sign in · CertTrack"
    assert_select "h1", "CertTrack"
    assert_select "form[action=?]", session_path do
      assert_select "input[name=email_address]"
      assert_select "input[name=password]"
    end
    assert_select "a[href=?]", new_password_path
    assert_select "nav", count: 0
  end

  test "new pre-fills the email from the query string" do
    get new_session_path(email_address: "ivy@example.com")
    assert_select "input[name=email_address][value=?]", "ivy@example.com"
  end

  test "there is no public sign-up" do
    get new_session_path
    assert_select "a[href*=sign_up], a[href*=register], a[href=?]", new_user_path, count: 0
  end

  test "create with valid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "password" }

    assert_redirected_to root_path
    assert cookies[:session_id]
    assert_equal 1, @user.sessions.count
  end

  test "create returns to the page that required sign-in" do
    sign_in_as users(:admin)
    sign_out
    get users_path
    assert_redirected_to new_session_path

    post session_path, params: { email_address: "admin@example.com", password: "password" }
    assert_redirected_to users_url
  end

  test "create with invalid credentials shows the error once" do
    post session_path, params: { email_address: @user.email_address, password: "wrong" }

    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]

    follow_redirect!
    assert_select "[role=alert]", count: 1, text: "Try another email address or password."
  end

  test "destroy signs out" do
    sign_in_as(@user)

    delete session_path

    assert_redirected_to new_session_path
    assert_empty cookies[:session_id]
    assert_equal 0, @user.sessions.count

    get root_path
    assert_redirected_to new_session_path
  end
end
