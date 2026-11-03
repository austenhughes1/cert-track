# Password resets and invite acceptance share the set-password form. Reset links
# expire in 15 minutes; invite links (UserMailer.invite) last User::INVITATION_EXPIRES_IN.
# Both die once the password changes because both tokens are keyed on the password salt.
class PasswordsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_user_by_token, only: %i[ edit update ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_password_path, alert: "Try again later." }

  def new
  end

  def create
    if user = User.find_by(email_address: params[:email_address])
      PasswordsMailer.reset(user).deliver_later
    end

    redirect_to new_session_path, notice: "Password reset instructions sent (if user with that email address exists)."
  end

  def edit
  end

  def update
    if change_password
      @user.sessions.destroy_all
      notice = @invitation ? "Password set. Sign in to get started." : "Password has been reset."
      redirect_to new_session_path(email_address: @user.email_address), notice: notice
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_user_by_token
      if @user = User.find_by_password_reset_token(params[:token])
        @invitation = false
      elsif @user = User.find_by_invitation_token(params[:token])
        @invitation = true
      else
        redirect_to new_password_path, alert: "That link is invalid or has expired. Request a new one below."
      end
    end

    def change_password
      if params[:password].blank?
        @user.errors.add(:password, :blank)
        false
      else
        @user.update(params.permit(:password, :password_confirmation))
      end
    end
end
