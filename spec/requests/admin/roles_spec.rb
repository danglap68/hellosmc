require "rails_helper"

RSpec.describe "Role permissions" do
  let(:admin) { create(:user, :admin) }

  def grant_params(key, overrides = {})
    grants = {}
    Role.find_by!(key: key).role_permissions.each do |permission|
      grants[permission.resource] ||= {}
      grants[permission.resource][permission.ability] = "1"
    end
    overrides.each do |resource, abilities|
      grants[resource] ||= {}
      abilities.each do |ability, enabled|
        if enabled
          grants[resource][ability] = "1"
        else
          grants[resource].delete(ability)
        end
      end
    end
    { role_key: key, grants: grants }
  end

  context "as an admin" do
    before { sign_in admin }

    it "lists the seeded roles and shows only the selected role's grants" do
      get admin_settings_system_roles_path(role: "viewer")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Phân quyền", "Kế toán", "Đối soát", "Vận hành kho", "Lưu phân quyền")
      document = Nokogiri::HTML(response.body)
      expect(document.at_css(".role-editor-main .card-title").text.strip).to eq("Chỉ xem")
      expect(document.css("input[name='grants[transactions][manage]']").size).to eq(1)
      expect(document.at_css("input[name='grants[transactions][read]']")["checked"]).to eq("checked")
      expect(document.at_css("input[name='grants[transactions][manage]']")["checked"]).to be_nil
      expect(document.at_css("input[name='grants[users][read]']")["checked"]).to be_nil
      expect(document.css("table")).to be_empty

      get admin_settings_system_roles_path(role: "operator")

      document = Nokogiri::HTML(response.body)
      expect(document.at_css(".role-editor-main .card-title").text.strip).to eq("Vận hành")
      expect(document.at_css("input[name='grants[transactions][manage]']")["checked"]).to eq("checked")
      expect(document.at_css("input[name='grants[users][manage]']")["checked"]).to be_nil
    end

    it "keeps the admin role locked" do
      get admin_settings_system_roles_path(role: "admin")

      box = Nokogiri::HTML(response.body).at_css("input[name='grants[users][manage]']")
      expect(box["disabled"]).to eq("disabled")
      expect(box["checked"]).to eq("checked")
      expect(response.body).not_to include("Lưu phân quyền")

      patch grants_admin_roles_path, params: { role_key: "admin", grants: {} }

      expect(response).to redirect_to(admin_settings_system_roles_path(role: "admin"))
      expect(Role.find_by!(key: "admin").granted?(:users, :manage)).to be(true)
      expect(create(:user, :admin).can?(:manage, :users)).to be(true)
    end

    it "links the screen from Cài đặt" do
      get admin_settings_system_users_path

      expect(response.body).to include(admin_settings_system_roles_path)
      expect(response.body).to include("Phân quyền")
    end

    it "turns operator approval off, while leaving the list readable" do
      patch grants_admin_roles_path, params: grant_params("operator", "transactions" => { "manage" => false })

      expect(response).to redirect_to(admin_settings_system_roles_path(role: "operator"))
      expect(flash[:notice]).to eq("Đã lưu phân quyền.")
      operator = Role.find_by!(key: "operator")
      expect(operator.granted?(:transactions, :manage)).to be(false)
      expect(operator.granted?(:transactions, :read)).to be(true)
      expect(Role.find_by!(key: "viewer").granted?(:transactions, :read)).to be(true)
      expect(AuditLog.where(action: "role.permissions_updated", actor_id: admin.id)).to exist

      sign_in create(:user, :operator)
      get admin_transactions_path
      expect(response).to have_http_status(:ok)
      post approve_admin_transaction_path(0)
      expect(response).to have_http_status(:forbidden)
    end

    it "grants a viewer a screen they could not open, including a write" do
      patch grants_admin_roles_path, params: grant_params(
        "viewer", "dealers" => { "read" => true, "manage" => true }
      )

      sign_in create(:user, :viewer)
      expect {
        post admin_dealers_path, params: { dealer: { name: "Đại lý mới", code: "MOI" } }
      }.to change(Dealer, :count).by(1)
    end

    it "removes a screen from a role" do
      patch grants_admin_roles_path, params: grant_params("operator", "fee_rules" => { "read" => false })

      sign_in create(:user, :operator)
      get admin_settings_fees_rules_path
      expect(response).to have_http_status(:forbidden)
    end

    it "adds a role, offers it when creating a user, and that user only has the grants that were turned on" do
      post admin_roles_path, params: { role: { name: "Ca chiều" } }

      expect(response).to redirect_to(admin_settings_system_roles_path(role: "ca_chieu"))
      role = Role.find_by!(key: "ca_chieu")
      expect(AuditLog.where(action: "role.created", auditable: role)).to exist

      get new_admin_user_path
      expect(response.body).to include("Ca chiều")

      patch grants_admin_roles_path, params: { role_key: "ca_chieu", grants: { "dashboard" => { "read" => "1" } } }
      user = create(:user, role: "ca_chieu")
      sign_in user

      get admin_root_path
      expect(response).to have_http_status(:ok)
      get admin_settings_system_roles_path
      expect(response).to have_http_status(:forbidden)
      expect(user.can?(:manage, :transactions)).to be(false)
    end

    it "rejects a blank role name and keeps the role list on the page" do
      post admin_roles_path, params: { role: { name: " " } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Tên vai trò")
      expect(Role.where(system: false)).not_to exist
    end

    it "deletes a custom role with nobody assigned, and refuses a built-in role or one in use" do
      spare = Role.build_custom("Ca sáng").tap(&:save!)
      used = Role.build_custom("Ca đêm").tap(&:save!)
      create(:user, role: used.key)

      delete admin_role_path(spare)
      expect(response).to redirect_to(admin_settings_system_roles_path)
      expect(Role.where(key: "ca_sang")).not_to exist
      expect(AuditLog.where(action: "role.destroyed")).to exist

      delete admin_role_path(used)
      expect(flash[:alert]).to include("đang được gán")
      expect(Role.where(key: used.key)).to exist

      delete admin_role_path(Role.find_by!(key: "viewer"))
      expect(flash[:alert]).to include("Không xoá được vai trò có sẵn")
      expect(Role.where(key: "viewer")).to exist

      delete admin_role_path(Role.find_by!(key: "ke_toan"))
      expect(Role.where(key: "ke_toan")).to exist
    end

    it "ignores a forged screen name and a missing role" do
      params = grant_params("operator")
      params[:grants]["not_a_screen"] = { "manage" => "1" }

      patch grants_admin_roles_path, params: params

      expect(response).to redirect_to(admin_settings_system_roles_path(role: "operator"))
      expect(RolePermission.where(resource: "not_a_screen")).not_to exist

      patch grants_admin_roles_path, params: { role_key: "nobody", grants: {} }
      expect(response).to redirect_to(admin_settings_system_roles_path)
      expect(flash[:alert]).to eq("Không tìm thấy vai trò.")
    end
  end

  context "as a viewer" do
    before { sign_in create(:user, :viewer) }

    it "cannot open or save the grants" do
      get admin_settings_system_roles_path
      expect(response).to have_http_status(:forbidden)

      patch grants_admin_roles_path, params: grant_params("viewer", "users" => { "manage" => true })
      expect(response).to have_http_status(:forbidden)
      expect(Role.find_by!(key: "viewer").granted?(:users, :manage)).to be(false)
    end
  end

  context "as an operator" do
    before { sign_in create(:user, :operator) }

    it "cannot open the grants" do
      get admin_settings_system_roles_path
      expect(response).to have_http_status(:forbidden)
    end
  end

  context "with a role that may only look at the grants" do
    let(:role) { Role.build_custom("Kiểm soát").tap(&:save!) }

    before do
      role.replace_grants!([ %w[roles read], %w[dashboard read] ])
      sign_in create(:user, role: role.key)
    end

    it "shows the selected role without a save button and refuses a save" do
      get admin_settings_system_roles_path(role: "viewer")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Lưu phân quyền")
      expect(response.body).not_to include("Thêm vai trò")
      box = Nokogiri::HTML(response.body).at_css("input[name='grants[transactions][read]']")
      expect(box["disabled"]).to eq("disabled")
      expect(box["checked"]).to eq("checked")

      patch grants_admin_roles_path, params: grant_params("viewer", "users" => { "manage" => true })
      expect(response).to have_http_status(:forbidden)
      expect(Role.find_by!(key: "viewer").granted?(:users, :manage)).to be(false)
    end
  end
end
