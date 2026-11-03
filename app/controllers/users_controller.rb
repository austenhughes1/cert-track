class UsersController < ApplicationController
  require_role :admin
  before_action :set_user, only: %i[edit update destroy resend_invite]

  def index
    @users = User.with_last_sign_in.ordered.load
  end

  def new
    @user = User.new
  end

  # Invite-only: the account gets a random password and the invitee sets their own from the email.
  def create
    @user = User.new(user_params)
    @user.password = User.generate_password

    if @user.save
      UserMailer.invite(@user).deliver_later
      redirect_to users_path, notice: "Invite sent to #{@user.email_address}."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @user.update(user_params)
      # An admin who demotes themselves can no longer see this screen.
      destination = @user == Current.user && !@user.admin? ? root_path : users_path
      redirect_to destination, notice: "Saved #{@user.display_name}."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @user == Current.user
      redirect_to users_path, alert: "You can't delete your own account.", status: :see_other
    elsif @user.destroy
      redirect_to users_path, notice: "Deleted #{@user.display_name}.", status: :see_other
    else
      redirect_to users_path, alert: @user.errors.full_messages.to_sentence, status: :see_other
    end
  rescue ActiveRecord::InvalidForeignKey
    redirect_to users_path, status: :see_other,
      alert: "#{@user.display_name} is linked to certificates or imports and can't be deleted. Change their role to viewer instead."
  end

  def resend_invite
    UserMailer.invite(@user).deliver_later
    redirect_to users_path, notice: "Invite re-sent to #{@user.email_address}."
  end

  # Emails the signed-in admin today's daily digest from current data (sample data when
  # nothing is near expiry). Writes no ExpiryNotification rows; counts toward the 90/day cap.
  def send_test_digest
    return redirect_to(users_path, alert: "Today's email limit is used up. Try the test digest again tomorrow.") unless Notifications::SendBudget.reserve!

    items = Notifications::DigestBuilder.daily_items
    sample = items.empty?
    items = ExpiryMailer.sample_items if sample

    begin
      ExpiryMailer.with(user: Current.user, items: items, test: true, sample: sample).daily_digest.deliver_now
    rescue StandardError => error
      Notifications::SendBudget.release!
      Rails.error.report(error, handled: true, context: { user_id: Current.user.id })
      return redirect_to(users_path, alert: "Couldn't send the test digest (#{error.class}). Check the mail settings and try again.")
    end

    redirect_to users_path, notice: "Test digest sent to #{Current.user.email_address}"
  end

  private
    def set_user
      @user = User.find(params.expect(:id))
    end

    def user_params
      params.expect(user: %i[name email_address role receives_digest])
    end
end
