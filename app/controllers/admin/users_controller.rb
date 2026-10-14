module Admin
  class UsersController < BaseController
    permission :users

    before_action :set_user, only: %i[edit update destroy send_reset_password]
    before_action :authorize_role_assignment!, only: %i[create update]
    before_action :authorize_admin_account!, only: :edit
    around_action :lock_managed_account, only: %i[update destroy send_reset_password]

    def index
      scope = User.includes(:access_role)
      if params[:q].present?
        q = "%#{User.sanitize_sql_like(params[:q])}%"
        scope = scope.where("users.email ILIKE :q OR users.name ILIKE :q", q: q)
      end
      scope = scope.where(role: params[:role]) if params[:role].present? && Role.exists?(key: params[:role])
      scope = apply_active_filter(scope)
      scope = apply_sort(scope, {
        "email" => { email: :asc },
        "name_asc" => { name: :asc, email: :asc },
        "newest" => { created_at: :desc, id: :desc }
      }, default: "email")
      @pagy, @users = pagy(scope)
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

    def authorize_role_assignment!
      forbid! if !current_user.admin? && user_params[:role] == "admin"
    end

    def authorize_admin_account!
      forbid! unless @user.manageable_by?(current_user)
    end

    def lock_managed_account
      @user.with_lock do
        if @user.manageable_by?(current_user)
          yield
        else
          forbid!
        end
      end
    end

    def self_lockout?(attributes)
      return false unless @user == current_user

      (@user.admin? && attributes.key?(:role) && attributes[:role] != "admin") ||
        (attributes.key?(:active) && ActiveModel::Type::Boolean.new.cast(attributes[:active]) == false)
    end
  end
end
