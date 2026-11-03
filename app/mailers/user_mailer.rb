class UserMailer < ApplicationMailer
  # Invite-only accounts: the link opens the set-password form (PasswordsController#edit).
  def invite(user)
    @user = user
    @url = edit_password_url(user.invitation_token)
    mail subject: "You've been invited to CertTrack", to: user.email_address
  end
end
