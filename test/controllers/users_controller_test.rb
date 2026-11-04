require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup { @admin = users(:admin) }

  # --- Access ---

  test "anonymous users are sent to sign in" do
    get users_path
    assert_redirected_to new_session_path
  end

  test "managers and viewers get 403 on every users action" do
    target = users(:viewer)

    %i[manager viewer].each do |role|
      sign_in_as users(role)

      get users_path
      assert_response :forbidden, "#{role} index"
      get new_user_path
      assert_response :forbidden, "#{role} new"
      get edit_user_path(target)
      assert_response :forbidden, "#{role} edit"

      assert_no_difference -> { User.count } do
        post users_path, params: { user: { email_address: "sneaky@example.com", role: "admin" } }
      end
      assert_response :forbidden, "#{role} create"

      patch user_path(target), params: { user: { role: "admin" } }
      assert_response :forbidden, "#{role} update"
      assert target.reload.viewer?

      assert_no_difference -> { User.count } do
        delete user_path(target)
      end
      assert_response :forbidden, "#{role} destroy"

      assert_no_enqueued_emails do
        post resend_invite_user_path(target)
      end
      assert_response :forbidden, "#{role} resend_invite"

      sign_out
    end
  end

  # --- Index ---

  test "index lists users with role, digest and last sign-in" do
    travel_to(Time.zone.local(2026, 10, 5, 14, 30)) { users(:manager).sessions.create! }
    sign_in_as @admin

    get users_path

    assert_response :success
    assert_select "title", "Users · CertTrack"
    assert_select "tr#user_#{users(:manager).id}" do
      assert_select "td", "Manny Manager"
      assert_select "td", "manager@example.com"
      assert_select "td", "Manager"
      assert_select "td", "Yes"
      assert_select "time", "Oct 5, 2026 2:30 PM"
    end
    assert_select "tr#user_#{users(:viewer).id} td", "No"
    # The signed-in admin can't delete themselves (and is the only admin).
    assert_select "tr#user_#{@admin.id} form[action=?]", user_path(@admin), count: 0
    assert_select "tr#user_#{users(:viewer).id} form[action=?]", user_path(users(:viewer))
  end

  test "index runs a fixed number of queries regardless of user count" do
    5.times { |i| User.create!(email_address: "u#{i}@example.com", password: User.generate_password).sessions.create! }
    sign_in_as @admin

    queries = count_queries { get users_path }
    5.times { |i| User.create!(email_address: "v#{i}@example.com", password: User.generate_password).sessions.create! }
    assert_equal queries, count_queries { get users_path }
  end

  # --- Invite (new/create) ---

  test "new renders the invite form" do
    sign_in_as @admin
    get new_user_path

    assert_response :success
    assert_select "form[action=?]", users_path do
      assert_select "input[name=?]", "user[name]"
      assert_select "input[name=?]", "user[email_address]"
      assert_select "select[name=?]", "user[role]"
      assert_select "input[type=checkbox][name=?]", "user[receives_digest]"
    end
  end

  test "create invites a user and emails a link" do
    sign_in_as @admin

    assert_difference -> { User.count }, 1 do
      assert_enqueued_emails 1 do
        post users_path, params: { user: { name: "Nia New", email_address: "Nia@Example.com", role: "manager", receives_digest: "0" } }
      end
    end

    user = User.find_by!(email_address: "nia@example.com")
    assert_redirected_to users_path
    assert user.manager?
    assert_equal "Nia New", user.name
    assert_not user.receives_digest?
    assert_enqueued_email_with UserMailer, :invite, args: [ user ]
  end

  test "create shows validation errors" do
    sign_in_as @admin

    assert_no_difference -> { User.count } do
      post users_path, params: { user: { name: "Dup", email_address: "viewer@example.com", role: "viewer" } }
    end

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /Email address has already been taken/
  end

  test "create rejects an unknown role" do
    sign_in_as @admin

    assert_no_difference -> { User.count } do
      post users_path, params: { user: { email_address: "x@example.com", role: "owner" } }
    end
    assert_response :unprocessable_entity
    assert_select "#error_explanation", /Role/
  end

  test "an invited user sets a password from the email and signs in" do
    sign_in_as @admin
    perform_enqueued_jobs do
      post users_path, params: { user: { name: "Ivy Invitee", email_address: "ivy@example.com", role: "viewer" } }
    end
    sign_out

    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "ivy@example.com" ], mail.to
    link = mail.html_part.body.to_s[%r{http://example\.com(/passwords/[^"]+/edit)}, 1]
    assert link, "invite email should contain a set-password link"
    assert_includes mail.text_part.body.to_s, "http://example.com#{link}"

    get link
    assert_response :success
    assert_select "h2", "Set your password"

    put link.delete_suffix("/edit"), params: { password: "ivy's new password", password_confirmation: "ivy's new password" }
    assert_redirected_to new_session_path(email_address: "ivy@example.com")

    post session_path, params: { email_address: "ivy@example.com", password: "ivy's new password" }
    assert_redirected_to root_path
    assert cookies[:session_id].present?

    # The same link can't be used twice.
    sign_out
    get link
    assert_redirected_to new_password_path
  end

  test "an expired invite link is rejected" do
    token = users(:viewer).invitation_token

    travel 7.days + 1.minute do
      get edit_password_path(token)
      assert_redirected_to new_password_path
      follow_redirect!
      assert_select "[role=alert]", /invalid or has expired/
    end
  end

  # --- Edit/update ---

  test "edit renders the form" do
    sign_in_as @admin
    get edit_user_path(users(:viewer))

    assert_response :success
    assert_select "input[name=?][value=?]", "user[email_address]", "viewer@example.com"
  end

  test "update changes name, email, role and digest" do
    sign_in_as @admin
    viewer = users(:viewer)

    patch user_path(viewer), params: { user: { name: "Vera V.", email_address: "vera@example.com", role: "manager", receives_digest: "1" } }

    assert_redirected_to users_path
    viewer.reload
    assert_equal "Vera V.", viewer.name
    assert_equal "vera@example.com", viewer.email_address
    assert viewer.manager?
    assert viewer.receives_digest?
  end

  test "update ignores attributes outside the permitted list" do
    sign_in_as @admin
    viewer = users(:viewer)

    assert_no_changes -> { viewer.reload.password_digest } do
      patch user_path(viewer), params: { user: { name: "Vera", password: "hijacked password", password_digest: "x" } }
    end
  end

  test "update shows validation errors" do
    sign_in_as @admin
    patch user_path(users(:viewer)), params: { user: { email_address: "bad" } }

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /Email address is invalid/
  end

  test "the last admin cannot be demoted" do
    sign_in_as @admin
    patch user_path(@admin), params: { user: { role: "manager" } }

    assert_response :unprocessable_entity
    assert_select "#error_explanation", /only admin/
    assert @admin.reload.admin?
  end

  test "an admin who demotes themselves lands on the dashboard" do
    users(:manager).update!(role: :admin)
    sign_in_as @admin

    patch user_path(@admin), params: { user: { role: "viewer" } }

    assert_redirected_to root_path
    assert @admin.reload.viewer?
  end

  # --- Destroy ---

  test "destroy deletes another user" do
    doomed = User.create!(email_address: "doomed@example.com", password: User.generate_password)
    sign_in_as @admin

    assert_difference -> { User.count }, -1 do
      delete user_path(doomed)
    end
    assert_redirected_to users_path
  end

  test "destroy refuses users linked to tracker records" do
    uploader = User.create!(email_address: "uploader@example.com", password: User.generate_password, role: :manager)
    ImportBatch.create!(uploaded_by: uploader)
    sign_in_as @admin

    assert_no_difference -> { User.count } do
      delete user_path(uploader)
    end
    assert_redirected_to users_path
    follow_redirect!
    assert_select "[role=alert]", /linked to certificates or imports/
  end

  test "an admin cannot delete themselves" do
    users(:manager).update!(role: :admin) # not the last admin, still refused
    sign_in_as @admin

    assert_no_difference -> { User.count } do
      delete user_path(@admin)
    end
    assert_redirected_to users_path
    follow_redirect!
    assert_select "[role=alert]", /can't delete your own account/
  end

  test "an admin can delete another admin while one remains" do
    other = User.create!(email_address: "other-admin@example.com", password: User.generate_password, role: :admin)
    sign_in_as @admin

    delete user_path(other)

    assert_redirected_to users_path
    assert_nil User.find_by(id: other.id)
    assert @admin.reload.last_admin?
    # The model guard (test/models/user_test.rb) keeps this last admin from being deleted or demoted.
    assert_not @admin.destroy
  end

  # --- Resend invite ---

  test "resend_invite emails a fresh link" do
    sign_in_as @admin

    assert_enqueued_email_with UserMailer, :invite, args: [ users(:viewer) ] do
      post resend_invite_user_path(users(:viewer))
    end
    assert_redirected_to users_path
  end

  # --- Send test digest ---

  test "index has a send test digest button" do
    sign_in_as @admin
    get users_path

    assert_select "form[action=?][method=post] button", send_test_digest_users_path, text: "Send test digest to me"
  end

  test "send_test_digest emails the admin today's digest without logging notifications" do
    sign_in_as @admin

    assert_no_difference -> { ExpiryNotification.count } do
      assert_difference -> { Notifications::SendBudget.sent_today }, 1 do
        assert_emails 1 do
          post send_test_digest_users_path
        end
      end
    end

    assert_redirected_to users_path
    assert_equal "Test digest sent to admin@example.com", flash[:notice]

    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "admin@example.com" ], mail.to
    assert_match(/\A\[Test\] CertTrack: \d+ certificates? needs? attention\z/, mail.subject)
    text = mail.text_part.body.to_s
    assert_includes text, "Built from today's data"
    assert_includes text, "Juan Ortiz: http://example.com/crew_members/#{crew_members(:juan_ortiz).id}"
    assert_not_includes text, "Sam Price" # inactive crew members are left out
  end

  test "send_test_digest sends sample data when nothing is near expiry" do
    Certificate.update_all(expires_on: nil)
    sign_in_as @admin

    assert_emails 1 do
      post send_test_digest_users_path
    end

    mail = ActionMailer::Base.deliveries.last
    assert_equal "[Test] CertTrack: 3 certificates need attention", mail.subject
    assert_includes mail.text_part.body.to_s, "made-up sample data"
    assert_redirected_to users_path
  end

  test "send_test_digest refuses once today's email cap is used up" do
    Notifications::SendBudget.record!(Notifications::SendBudget.daily_limit)
    sign_in_as @admin

    assert_no_emails do
      post send_test_digest_users_path
    end
    assert_redirected_to users_path
    assert_match(/email limit is used up/, flash[:alert])
  end

  test "send_test_digest reports a delivery failure and hands back the send" do
    ActionMailer::Base.add_delivery_method :failing_for_test, FailingDelivery
    previous = ExpiryMailer.delivery_method
    ExpiryMailer.delivery_method = :failing_for_test
    sign_in_as @admin

    assert_no_difference -> { Notifications::SendBudget.sent_today } do
      post send_test_digest_users_path
    end
    assert_redirected_to users_path
    assert_match(/Couldn't send the test digest \(Net::SMTPFatalError\)/, flash[:alert])
  ensure
    ExpiryMailer.delivery_method = previous
  end

  test "managers and viewers get 403 on send_test_digest" do
    %i[manager viewer].each do |role|
      sign_in_as users(role)

      assert_no_emails do
        post send_test_digest_users_path
      end
      assert_response :forbidden, "#{role} send_test_digest"

      sign_out
    end
  end

  class FailingDelivery
    def initialize(_settings) = nil

    def deliver!(_mail)
      raise Net::SMTPFatalError, "550 sender not verified"
    end
  end

  private
    def count_queries(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
end
