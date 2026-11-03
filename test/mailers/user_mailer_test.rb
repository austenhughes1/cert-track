require "test_helper"

class UserMailerTest < ActionMailer::TestCase
  test "invite links to the set-password form with an invitation token" do
    user = users(:manager)
    mail = UserMailer.invite(user)

    assert_equal [ "manager@example.com" ], mail.to
    assert_equal "You've been invited to CertTrack", mail.subject

    html = mail.html_part.body.to_s
    text = mail.text_part.body.to_s
    token = html[%r{http://example\.com/passwords/([^/"]+)/edit}, 1]

    assert token, "expected a set-password link in the HTML part"
    assert_includes text, "http://example.com/passwords/#{token}/edit"
    assert_equal user, User.find_by_invitation_token(CGI.unescape(token))
    assert_includes text, "Manny Manager"
    assert_includes text, "manager access"
    assert_includes text, "7 days"
  end

  test "invite greets users without a name" do
    user = User.create!(email_address: "nameless@example.com", password: User.generate_password)
    assert_includes UserMailer.invite(user).text_part.body.to_s, "Hi there,"
  end
end
