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

  test "create sends one reset email per user per link lifetime, and answers every request the same" do
    with_real_cache do
      3.times { post passwords_path, params: { email_address: @user.email_address } }
      assert_enqueued_emails 1
      assert_redirected_to new_session_path
      follow_redirect!
      assert_notice "reset instructions sent"

      post passwords_path, params: { email_address: users(:admin).email_address }
      assert_enqueued_emails 2 # another user's reset still goes

      travel PasswordsController::RESET_EMAIL_INTERVAL + 1.second do
        post passwords_path, params: { email_address: @user.email_address }
        assert_enqueued_emails 3
      end
    end
  end

  test "create sends one user at most RESET_EMAILS_PER_USER_PER_DAY reset emails a day, so one known address can't use up everyone's" do
    travel_to Time.zone.local(2026, 11, 4, 8, 0)
    with_real_cache do
      (PasswordsController::RESET_EMAILS_PER_USER_PER_DAY + 2).times do |i|
        travel_to Time.current + i * (PasswordsController::RESET_EMAIL_INTERVAL + 1.second) do
          post passwords_path, params: { email_address: @user.email_address }
        end
      end
      assert_enqueued_emails PasswordsController::RESET_EMAILS_PER_USER_PER_DAY
      assert_redirected_to new_session_path

      post passwords_path, params: { email_address: users(:admin).email_address }
      assert_enqueued_emails PasswordsController::RESET_EMAILS_PER_USER_PER_DAY + 1
    end
  end

  test "create sends at most RESET_EMAILS_PER_DAY reset emails a Denver day in all" do
    travel_to Time.zone.local(2026, 11, 4, 12, 0)
    with_real_cache do
      Rails.cache.write("password_resets/sent/#{Date.current.iso8601}", PasswordsController::RESET_EMAILS_PER_DAY - 1)

      post passwords_path, params: { email_address: @user.email_address }
      post passwords_path, params: { email_address: users(:admin).email_address }
      assert_enqueued_emails 1
      assert_redirected_to new_session_path

      travel_to Date.current.tomorrow.in_time_zone.change(hour: 0, minute: 1) do
        post passwords_path, params: { email_address: users(:admin).email_address }
        assert_enqueued_emails 2
      end
    end
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
    # The test environment uses :null_store; the reset throttle needs a real cache.
    def with_real_cache
      original = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      yield
    ensure
      Rails.cache = original
    end

    def assert_notice(text)
      assert_select "[role=status]", /#{text}/
    end

    def assert_alert(text)
      assert_select "[role=alert]", /#{text}/
    end
end
