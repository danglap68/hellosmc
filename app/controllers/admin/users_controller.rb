module Admin
  class UsersController < BaseController
    permission :users

    before_action :set_user, only: %i[edit update destroy send_reset_password]

    def index
      @pagy, @users = pagy(User.ordered)
    end

    def new
      @user = User.new(role: "operator", active: true)
    end

    # When no password is given, a random one is set and a reset link is emailed.
    def create
      @user = User.new(user_params)
      send_reset = @user.password.blank?
      if send_reset
        @user.password = @user.password_confirmation = SecureRandom.base58(24)
      end

      if @user.save
        @user.send_reset_password_instructions if send_reset
        audit!("user.created", @user)
        redirect_to admin_users_path, notice: t("flash.created", model: User.model_name.human)
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      attributes = user_params
      attributes = attributes.except(:password, :password_confirmation) if attributes[:password].blank?
      if self_lockout?(attributes)
        @user.assign_attributes(attributes)
        @user.errors.add(:base, :cannot_demote_self)
        return render :edit, status: :unprocessable_content
      end

      before = Audit::Snapshot.of(@user)
      if @user.update(attributes)
        audit!("user.updated", @user, before: before)
        bypass_sign_in(@user) if @user == current_user && attributes[:password].present?
        redirect_to admin_users_path, notice: t("flash.updated", model: User.model_name.human)
      else
        render :edit, status: :unprocessable_content
      end
    end

    # Users are deactivated rather than deleted when they have history.
    def destroy
      if @user == current_user
        return redirect_to(admin_users_path, alert: t("users.flash.cannot_delete_self"), status: :see_other)
      end

      before = Audit::Snapshot.of(@user)
      if @user.destroy
        audit!("user.destroyed", @user, before: before)
        redirect_to admin_users_path, notice: t("flash.destroyed", model: User.model_name.human), status: :see_other
      else
        redirect_to admin_users_path, alert: @user.errors.full_messages.to_sentence, status: :see_other
      end
    rescue ActiveRecord::InvalidForeignKey
      redirect_to admin_users_path, alert: t("users.flash.has_history"), status: :see_other
    end

    def send_reset_password
      @user.send_reset_password_instructions
      audit!("user.password_reset_sent", @user)
      redirect_to admin_users_path, notice: t("users.flash.reset_sent", email: @user.email)
    end

    private

    def set_user
      @user = User.find(params[:id])
    end

    def user_params
      params.require(:user).permit(:email, :name, :role, :active, :password, :password_confirmation)
    end

    def self_lockout?(attributes)
      return false unless @user == current_user

      (attributes.key?(:role) && attributes[:role] != "admin") ||
        (attributes.key?(:active) && ActiveModel::Type::Boolean.new.cast(attributes[:active]) == false)
    end
  end
end
