require "rails_helper"

RSpec.describe Roles::Matrix do
  let(:actor) { create(:user, :admin) }

  it "turns a grant off, and keeps read when manage is the only box sent" do
    viewer = Role.find_by!(key: "viewer")

    described_class.apply!(
      actor: actor,
      role: viewer,
      grants: { "dealers" => { "manage" => "1" }, "dashboard" => { "read" => "1" } }
    )

    expect(viewer.role_permissions.where(resource: "dealers").pluck(:ability)).to contain_exactly("read", "manage")
    expect(viewer.role_permissions.where(resource: "transactions")).not_to exist
    expect(viewer.granted?(:dashboard, :read)).to be(true)
    expect(viewer.granted?(:dashboard, :manage)).to be(false)
    expect(Role.find_by!(key: "operator").granted?(:transactions, :manage)).to be(true)
  end

  it "ignores an unknown screen" do
    viewer = Role.find_by!(key: "viewer")

    described_class.apply!(
      actor: actor,
      role: viewer,
      grants: { "not_a_screen" => { "manage" => "1" }, "dashboard" => { "read" => "1" } }
    )

    expect(RolePermission.where(resource: "not_a_screen")).not_to exist
    expect(viewer.granted?(:dashboard, :read)).to be(true)
  end

  it "renames a role and writes one audit entry" do
    viewer = Role.find_by!(key: "viewer")

    described_class.apply!(actor: actor, role: viewer, name: "Khách", grants: grants_of(viewer))

    expect(viewer.reload.name).to eq("Khách")
    log = AuditLog.where(action: "role.permissions_updated", auditable: viewer).sole
    expect(log.actor_id).to eq(actor.id)
    expect(log.before_data["name"]).to eq("Chỉ xem")
    expect(log.after_data["name"]).to eq("Khách")
  end

  it "does not audit a save that changes nothing" do
    viewer = Role.find_by!(key: "viewer")

    expect {
      described_class.apply!(actor: actor, role: viewer, grants: grants_of(viewer))
    }.not_to change(AuditLog, :count)
  end

  it "does not let a save empty or rename the admin role" do
    admin = Role.find_by!(key: "admin")
    before = admin.role_permissions.count

    described_class.apply!(actor: actor, role: admin, name: "Khác", grants: {})

    expect(admin.reload.name).to eq("Quản trị")
    expect(admin.role_permissions.count).to eq(before)
    expect(create(:user, :admin).can?(:manage, :roles)).to be(true)
  end

  it "rolls the save back when the name is blank" do
    operator = Role.find_by!(key: "operator")

    expect {
      described_class.apply!(actor: actor, role: operator, name: " ", grants: {})
    }.to raise_error(ActiveRecord::RecordInvalid)

    expect(operator.reload.name).to eq("Vận hành")
    expect(operator.granted?(:transactions, :manage)).to be(true)
  end

  def grants_of(role)
    grants = {}
    role.role_permissions.each do |permission|
      grants[permission.resource] ||= {}
      grants[permission.resource][permission.ability] = "1"
    end
    grants
  end
end
