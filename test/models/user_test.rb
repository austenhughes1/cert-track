require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  test "squishes name and stores blank as nil" do
    assert_equal "Pat Example", User.new(name: "  Pat   Example ").name
    assert_nil User.new(name: "   ").name
  end

  test "defaults to viewer with digest on" do
    user = User.new
    assert user.viewer?
    assert user.receives_digest?
  end

  test "rejects unknown roles without raising" do
    user = users(:viewer)
    user.role = "superuser"
    assert_not user.valid?
    assert user.errors.of_kind?(:role, :inclusion)
  end

  test "requires a unique, well-formed email" do
    assert_not User.new(email_address: "ADMIN@example.com", password: "long enough").valid?
    assert_not User.new(email_address: "not-an-email", password: "long enough").valid?
    assert User.new(email_address: "new@example.com", password: "long enough").valid?
  end

  test "requires passwords of at least 8 characters" do
    user = users(:viewer)
    user.password = "short"
    assert_not user.valid?
    assert user.errors.of_kind?(:password, :too_short)

    user.password = "eight888"
    assert user.valid?
  end

  test "editor? is true for admins and managers only" do
    assert users(:admin).editor?
    assert users(:manager).editor?
    assert_not users(:viewer).editor?
  end

  test "display_name falls back to email" do
    assert_equal "Ada Admin", users(:admin).display_name
    assert_equal "x@example.com", User.new(email_address: "x@example.com").display_name
  end

  test "digest_recipients are admins and managers who opted in" do
    users(:viewer).update!(receives_digest: true)
    users(:manager).update!(receives_digest: false)

    assert_equal [ users(:admin) ], User.digest_recipients.to_a
  end

  test "generate_password is long and random" do
    password = User.generate_password
    assert_operator password.length, :>=, 20
    assert_not_equal password, User.generate_password
  end

  # --- Last-admin protection ---

  test "the only admin cannot be demoted" do
    admin = users(:admin)
    assert admin.last_admin?
    assert_not admin.update(role: :manager)
    assert_includes admin.errors[:role], "can't be changed: this is the only admin"
    assert admin.reload.admin?
  end

  test "an admin can be demoted while another admin exists" do
    users(:manager).update!(role: :admin)
    assert_not users(:admin).last_admin?
    assert users(:admin).update(role: :viewer)
  end

  test "last-admin checks lock the admin rows so overlapping demotions queue" do
    second = User.create!(email_address: "second-admin@example.com", password: User.generate_password, role: :admin)

    assert_queries_match(/FROM "users" WHERE "users"."role" = .* FOR UPDATE/) do
      assert second.update(role: :viewer)
    end
    assert_queries_match(/FOR UPDATE/) { assert_not users(:admin).destroy }
    assert_includes users(:admin).errors[:base], "The only admin can't be deleted"
  end

  test "the only admin cannot be destroyed" do
    admin = users(:admin)
    assert_no_difference -> { User.count } do
      assert_not admin.destroy
    end
    assert_includes admin.errors[:base], "The only admin can't be deleted"
  end

  test "an admin can be destroyed while another admin exists" do
    second = User.create!(email_address: "second-admin@example.com", password: User.generate_password, role: :admin)
    assert_difference -> { User.count }, -1 do
      second.destroy!
    end
  end

  test "destroying a user removes their sessions" do
    user = User.create!(email_address: "short-lived@example.com", password: User.generate_password)
    user.sessions.create!
    assert_difference -> { Session.count }, -1 do
      user.destroy!
    end
  end

  # --- Invitation tokens ---

  test "invitation token finds the user and lasts 7 days" do
    user = users(:viewer)
    token = user.invitation_token

    assert_equal user, User.find_by_invitation_token(token)
    travel 7.days - 1.minute do
      assert_equal user, User.find_by_invitation_token(token)
    end
    travel 7.days + 1.minute do
      assert_nil User.find_by_invitation_token(token)
    end
  end

  test "invitation token stops working once the password changes" do
    user = users(:viewer)
    token = user.invitation_token
    user.update!(password: "a brand new password")

    assert_nil User.find_by_invitation_token(token)
  end

  test "changing the email address invalidates invitation and reset tokens already sent" do
    user = users(:viewer)
    invitation, reset = user.invitation_token, user.password_reset_token
    assert_equal user, User.find_by_invitation_token(invitation)
    assert_equal user, User.find_by_password_reset_token(reset)

    user.update!(email_address: "corrected@example.com")

    assert_nil User.find_by_invitation_token(invitation)
    assert_nil User.find_by_password_reset_token(reset)
    assert_equal user, User.find_by_invitation_token(user.invitation_token)
    assert_equal user, User.find_by_password_reset_token(user.password_reset_token)
  end

  test "reset tokens still last 15 minutes and stop working once the password changes" do
    user = users(:viewer)
    token = user.password_reset_token

    travel(14.minutes) { assert_equal user, User.find_by_password_reset_token(token) }
    travel(16.minutes) { assert_nil User.find_by_password_reset_token(token) }

    user.update!(password: "a brand new password")
    assert_nil User.find_by_password_reset_token(token)
  end

  test "tokens carry a digest of the email address, not the address itself" do
    user = users(:viewer)

    [ user.invitation_token, user.password_reset_token ].each do |token|
      payload = Base64.urlsafe_decode64(token.split("--").first)
      assert_no_match(/#{Regexp.escape(user.email_address)}/, payload)
      assert_includes payload, Digest::SHA256.hexdigest(user.email_address).first(16)
    end
  end

  test "invitation and password reset tokens are not interchangeable" do
    user = users(:viewer)
    assert_nil User.find_by_password_reset_token(user.invitation_token)
    assert_nil User.find_by_invitation_token(user.password_reset_token)
  end

  # --- Last sign-in ---

  test "with_last_sign_in exposes the latest session start per user" do
    admin = users(:admin)
    travel_to(Time.zone.local(2026, 10, 1, 9, 0)) { admin.sessions.create! }
    travel_to(Time.zone.local(2026, 10, 5, 14, 30)) { admin.sessions.create! }

    rows = User.with_last_sign_in.ordered.index_by(&:id)

    assert_equal Time.zone.local(2026, 10, 5, 14, 30), rows[admin.id].last_signed_in_at
    assert_equal "America/Denver", rows[admin.id].last_signed_in_at.time_zone.name
    assert_nil rows[users(:viewer).id].last_signed_in_at
    assert_equal User.count, rows.size
  end

  test "last_signed_in_at queries sessions when not preloaded" do
    user = users(:manager)
    assert_nil user.last_signed_in_at
    session = user.sessions.create!
    assert_equal session.created_at, user.last_signed_in_at
  end

  # --- certtrack:create_admin backing method ---

  test "create_or_promote_admin! creates a new admin" do
    user = User.create_or_promote_admin!(email_address: " Boss@Example.com ", name: "Bo Boss", password: "correct horse")

    assert user.persisted?
    assert user.admin?
    assert_equal "boss@example.com", user.email_address
    assert_equal "Bo Boss", user.name
    assert user.authenticate("correct horse")
  end

  test "create_or_promote_admin! promotes an existing user and keeps their password when none is given" do
    viewer = users(:viewer)
    digest = viewer.password_digest

    user = User.create_or_promote_admin!(email_address: "VIEWER@example.com")

    assert_equal viewer.id, user.id
    assert viewer.reload.admin?
    assert_equal digest, viewer.password_digest
    assert_equal "Vera Viewer", viewer.name
  end

  test "create_or_promote_admin! changes the password when given" do
    User.create_or_promote_admin!(email_address: "viewer@example.com", password: "another password")
    assert users(:viewer).reload.authenticate("another password")
  end
end
