# Preview all emails at http://localhost:3000/rails/mailers/user_mailer
class UserMailerPreview < ActionMailer::Preview
  # Preview this email at http://localhost:3000/rails/mailers/user_mailer/invite
  def invite
    user = User.where.not(role: :admin).take || User.take ||
      User.new(id: 0, name: "Pat Example", email_address: "pat@example.com", role: :manager, password: User.generate_password)
    UserMailer.invite(user)
  end
end
