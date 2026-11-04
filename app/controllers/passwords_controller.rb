# Password resets and invite acceptance share the set-password form. Reset links
# expire in 15 minutes; invite links (UserMailer.invite) last User::INVITATION_EXPIRES_IN.
# Both die once the password changes because both tokens are keyed on the password salt.
#
# Reset emails go out through the office's Gmail account without being counted by
# Notifications::SendBudget, so a script posting this form could otherwise use up the
# account's own daily Gmail limit, and with it the owner's mail. So each user gets at most one
# reset email per RESET_EMAIL_INTERVAL (the link's lifetime: the first link still works) and
# RESET_EMAILS_PER_USER_PER_DAY a Denver day, and all users together at most
# RESET_EMAILS_PER_DAY. The per-user cap means someone who knows one address can't use up
# everyone's resets. A request held back gets the same answer as any other, so the form never
# tells whether an address has an account.
class PasswordsController < ApplicationController
  RESET_EMAIL_INTERVAL = ActiveModel::SecurePassword::DEFAULT_RESET_TOKEN_EXPIRES_IN # 15 minutes
  RESET_EMAILS_PER_USER_PER_DAY = 4
  RESET_EMAILS_PER_DAY = 100

  allow_unauthenticated_access
  before_action :set_user_by_token, only: %i[ edit update ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_password_path, alert: "Try again later." }

  def new
  end

  def create
    if (user = User.find_by(email_address: params[:email_address])) && send_reset_email?(user)
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
    # Counts live in Rails.cache (Solid Cache in production), shared by every app process and
    # kept across restarts. Without a cache (nil counts) the email goes.
    def send_reset_email?(user)
      return false unless Rails.cache.write("password_resets/user/#{user.id}", true, expires_in: RESET_EMAIL_INTERVAL, unless_exist: true)

      today = Date.current.iso8601
      if over_cap?("password_resets/user/#{user.id}/#{today}", RESET_EMAILS_PER_USER_PER_DAY)
        held_back(user, "#{RESET_EMAILS_PER_USER_PER_DAY} already sent to this user today")
      elsif over_cap?("password_resets/sent/#{today}", RESET_EMAILS_PER_DAY)
        held_back(user, "#{RESET_EMAILS_PER_DAY} already sent today")
      else
        true
      end
    end

    def over_cap?(key, cap)
      count = Rails.cache.increment(key, 1, expires_in: 2.days)
      count.present? && count > cap
    end

    def held_back(user, reason)
      Rails.logger.warn("[Passwords] reset email for user #{user.id} held back: #{reason}")
      false
    end

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
