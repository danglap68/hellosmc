module Admin
  class RolesController < BaseController
    permission :roles

    def index
      @new_role ||= Role.new
      load_editor
    end

    def create
      @new_role = Role.build_custom(role_params[:name])
      if @new_role.save
        audit!("role.created", @new_role)
        redirect_to admin_settings_system_roles_path(role: @new_role.key), notice: t("roles.flash.created", name: @new_role.name)
      else
        load_editor
        render :index, status: :unprocessable_content
      end
    end

    def grants
      role = Role.find_by(key: params[:role_key].to_s)
      return redirect_to(admin_settings_system_roles_path, alert: t("roles.flash.missing")) unless role

      Roles::Matrix.apply!(actor: current_user, role: role, grants: params[:grants] || {}, name: params[:name])
      redirect_to admin_settings_system_roles_path(role: role.key), notice: t("roles.flash.updated")
    rescue ActiveRecord::RecordInvalid => error
      @new_role = Role.new
      load_editor
      flash.now[:alert] = error.record.errors.full_messages.to_sentence
      render :index, status: :unprocessable_content
    end

    def destroy
      role = Role.find(params[:id])
      before = role.audit_snapshot
      if role.destroy
        audit!("role.destroyed", role, before: before)
        redirect_to admin_settings_system_roles_path, notice: t("roles.flash.destroyed", name: before["name"]), status: :see_other
      else
        redirect_to admin_settings_system_roles_path(role: role.key), alert: role.errors.full_messages.to_sentence, status: :see_other
      end
    end

    private

    def load_editor
      @roles = Role.ordered.includes(:role_permissions)
      @user_counts = User.group(:role).count
      key = [ params[:role], params[:role_key] ].find { |value| value.is_a?(String) && value.present? }
      @role = @roles.find { |role| role.key == key } || @roles.first
    end

    def role_params
      params.require(:role).permit(:name)
    end
  end
end