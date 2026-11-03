require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = users(:manager) }

  test "new" do
    get new_password_path

    assert_response :success
    assert_select "title", "Forgot password · CertTrack"
    assert_select "h1", "CertTrack"
  end

  test "create" do
    post passwords_path, params: { email_address: @user.email_address }
    assert_enqueued_email_with PasswordsMailer, :reset, args: [ @user ]
    assert_redirected_to new_session_path

    follow_redirect!
    assert_notice "reset instructions sent"
  end

  test "create for an unknown user redirects but sends no mail" do
    post passwords_path, params: { email_address: "missing-user@example.com" }
    assert_enqueued_emails 0
    assert_redirected_to new_session_path

    follow_redirect!
    assert_notice "reset instructions sent"
  end

  test "edit with a reset token" do
    get edit_password_path(@user.password_reset_token)

    assert_response :success
    assert_select "h2", "Choose a new password"
    assert_select "p", @user.email_address
  end

  test "edit with an invitation token" do
    get edit_password_path(@user.invitation_token)

    assert_response :success
    assert_select "title", "Set your password · CertTrack"
    assert_select "input[type=submit][value=?]", "Set password"
  end

  test "edit with invalid token" do
    get edit_password_path("invalid token")
    assert_redirected_to new_password_path

    follow_redirect!
    assert_alert "invalid or has expired"
  end

  test "edit with an expired reset token" do
    token = @user.password_reset_token
    travel 16.minutes do
      get edit_password_path(token)
      assert_redirected_to new_password_path
    end
  end

  test "update" do
    assert_changes -> { @user.reload.password_digest } do
      put password_path(@user.password_reset_token), params: { password: "new password", password_confirmation: "new password" }
      assert_redirected_to new_session_path(email_address: @user.email_address)
    end

    follow_redirect!
    assert_notice "Password has been reset"
  end

  test "update signs out existing sessions" do
    @user.sessions.create!
    put password_path(@user.password_reset_token), params: { password: "new password", password_confirmation: "new password" }
    assert_equal 0, @user.sessions.count
  end

  test "update with an invitation token sets the password" do
    put password_path(@user.invitation_token), params: { password: "first password", password_confirmation: "first password" }

    assert_redirected_to new_session_path(email_address: @user.email_address)
    assert @user.reload.authenticate("first password")
    follow_redirect!
    assert_notice "Password set"
  end

  test "a used token is rejected" do
    token = @user.invitation_token
    put password_path(token), params: { password: "first password", password_confirmation: "first password" }

    assert_no_changes -> { @user.reload.password_digest } do
      put password_path(token), params: { password: "second password", password_confirmation: "second password" }
    end
    assert_redirected_to new_password_path
  end

  test "update with non matching passwords" do
    token = @user.password_reset_token
    assert_no_changes -> { @user.reload.password_digest } do
      put password_path(token), params: { password: "no match one", password_confirmation: "no match two" }
      assert_response :unprocessable_entity
    end

    assert_alert "Password confirmation doesn't match"
  end

  test "update with a short password" do
    assert_no_changes -> { @user.reload.password_digest } do
      put password_path(@user.password_reset_token), params: { password: "short", password_confirmation: "short" }
    end

    assert_response :unprocessable_entity
    assert_alert "too short"
  end

  test "update with a blank password" do
    assert_no_changes -> { @user.reload.password_digest } do
      put password_path(@user.password_reset_token), params: { password: "", password_confirmation: "" }
    end

    assert_response :unprocessable_entity
    assert_alert "Password can't be blank"
  end

  private
    def assert_notice(text)
      assert_select "[role=status]", /#{text}/
    end

    def assert_alert(text)
      assert_select "[role=alert]", /#{text}/
    end
end
