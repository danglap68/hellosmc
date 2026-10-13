require "rails_helper"

RSpec.describe RolePermission do
  let(:role) { Role.find_by!(key: "viewer") }

  it "rejects an unknown screen or ability" do
    permission = role.role_permissions.build(resource: "not_a_screen", ability: "read")
    expect(permission).not_to be_valid
    expect(permission.errors[:resource]).to be_present

    permission = role.role_permissions.build(resource: "dashboard", ability: "destroy")
    expect(permission).not_to be_valid
    expect(permission.errors[:ability]).to be_present
  end

  it "rejects the same grant twice" do
    existing = role.role_permissions.find_by!(resource: "dashboard", ability: "read")
    duplicate = role.role_permissions.build(resource: existing.resource, ability: existing.ability)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:resource]).to be_present
  end

  it "rejects an ability outside read and manage in the database" do
    expect {
      described_class.new(role: role, resource: "dashboard", ability: "destroy").save!(validate: false)
    }.to raise_error(ActiveRecord::StatementInvalid)
  end
end
