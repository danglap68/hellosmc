require "rails_helper"

RSpec.describe "Delegated user management" do
  let(:admin) { create(:user, :admin) }
  let(:manager) do
    role = Role.build_custom("User manager")
    role.save!
    role.replace_grants!([ [ "users", "read" ], [ "users", "manage" ] ])
    create(:user, role: role.key)
  end

  before { sign_in manager }

  def attributes(role: "operator")
    { email: "new-user@example.test", name: "New user", role: role,
      password: "StrongPassword123!", password_confirmation: "StrongPassword123!" }
  end

  it "allows ordinary account management while excluding admin from role choices" do
    get new_admin_user_path
    roles = Nokogiri::HTML(response.body).css("select[name='user[role]'] option").map { |option| option["value"] }
    expect(roles).to include("operator")
    expect(roles).not_to include("admin")
    expect { post admin_users_path, params: { user: attributes } }.to change(User, :count).by(1)
    user = User.find_by!(email: "new-user@example.test")
    patch admin_user_path(user), params: { user: { name: "Updated" } }
    expect(user.reload.name).to eq("Updated")
    patch admin_user_path(manager), params: { user: { name: "Self update" } }
    expect(manager.reload.name).to eq("Self update")
    patch admin_user_path(manager), params: { user: { active: false } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(manager.reload).to be_active
  end

  it "forbids creating or promoting administrators, including the manager's own account" do
    expect { post admin_users_path, params: { user: attributes(role: "admin") } }.not_to change(User, :count)
    expect(response).to have_http_status(:forbidden)
    [ manager, create(:user, :operator) ].each do |user|
      patch admin_user_path(user), params: { user: { role: "admin" } }
      expect(response).to have_http_status(:forbidden)
      expect(user.reload).not_to be_admin
    end
  end

  it "forbids modifying, deleting or resetting a protected administrator" do
    original = admin.attributes
    get edit_admin_user_path(admin)
    expect(response).to have_http_status(:forbidden)
    patch admin_user_path(admin), params: { user: { email: "takeover@example.test", password: "ChangedPassword123!", active: false, role: "operator" } }
    expect(response).to have_http_status(:forbidden)
    delete admin_user_path(admin)
    expect(response).to have_http_status(:forbidden)
    expect { post send_reset_password_admin_user_path(admin) }.not_to change(ActionMailer::Base.deliveries, :count)
    expect(response).to have_http_status(:forbidden)
    expect(admin.reload.attributes).to eq(original)
  end

  it "enforces the administrator boundary for mixed bulk selections" do
    ordinary = create(:user, :operator)
    %w[deactivate destroy].each do |operation|
      post admin_bulk_actions_path, params: {
        resource: "users", operation: operation, ids: [ admin.id, ordinary.id ],
        versions: [ admin, ordinary ].to_h { |user| [ user.id.to_s, BulkActions::Catalog.version(user) ] }
      }, as: :json
      expect(response.parsed_body.fetch("results").pluck("success")).to eq([ false, true ])
      expect(admin.reload).to be_active
      ordinary.reload unless operation == "destroy"
    end
  end

  it "continues to let administrators create admins and reset another admin" do
    sign_in admin
    expect { post admin_users_path, params: { user: attributes(role: "admin") } }.to change(User, :count).by(1)
    target = User.find_by!(email: "new-user@example.test")
    expect(target).to be_admin
    expect { post send_reset_password_admin_user_path(target) }.to change(ActionMailer::Base.deliveries, :count).by(1)
    patch admin_user_path(admin), params: { user: { role: "operator", active: false } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(admin.reload).to be_admin
    expect(admin).to be_active
  end
end
