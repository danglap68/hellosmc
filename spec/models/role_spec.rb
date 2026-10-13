require "rails_helper"

RSpec.describe Role do
  it "seeds the built-in roles with their starting grants" do
    expect(described_class.order(:position).pluck(:key)).to eq(%w[admin operator viewer ke_toan doi_soat van_hanh_kho])
    expect(described_class.find_by!(key: "operator")).to be_system
    expect(described_class.find_by!(key: "admin").granted?(:users, :manage)).to be(true)
    expect(described_class.find_by!(key: "viewer").granted?(:transactions, :manage)).to be(false)
    expect(described_class.find_by!(key: "viewer").granted?(:transactions, :read)).to be(true)

    accountant = described_class.find_by!(key: "ke_toan")
    expect(accountant.name).to eq("Kế toán")
    expect(accountant).to be_system
    expect(accountant.granted?(:excel_exports, :manage)).to be(true)
    expect(accountant.granted?(:transactions, :manage)).to be(false)
    expect(accountant.granted?(:fee_rules, :read)).to be(true)
    expect(accountant.granted?(:users, :read)).to be(false)

    reconciliation = described_class.find_by!(key: "doi_soat")
    expect(reconciliation.name).to eq("Đối soát")
    expect(reconciliation.granted?(:reviews, :manage)).to be(true)
    expect(reconciliation.granted?(:transactions, :manage)).to be(false)

    warehouse = described_class.find_by!(key: "van_hanh_kho")
    expect(warehouse.name).to eq("Vận hành kho")
    expect(warehouse.granted?(:bill_uploads, :manage)).to be(true)
    expect(warehouse.granted?(:reviews, :manage)).to be(false)
    expect(warehouse.granted?(:users, :read)).to be(false)
  end

  it "does not put a permission back after it was turned off" do
    operator = described_class.find_by!(key: "operator")
    operator.role_permissions.where(resource: "transactions", ability: "manage").delete_all

    described_class.seed_defaults!

    expect(operator.role_permissions.where(resource: "transactions", ability: "manage")).not_to exist
  end

  it "fills the starting grants when a built-in role has none, and can restore them on purpose" do
    operator = described_class.find_by!(key: "operator")
    operator.role_permissions.delete_all

    described_class.seed_defaults!
    expect(operator.reload.granted?(:transactions, :manage)).to be(true)

    operator.role_permissions.where(resource: "transactions", ability: "manage").delete_all
    described_class.seed_defaults!(reset_system_grants: true)
    expect(operator.reload.granted?(:transactions, :manage)).to be(true)
  end

  describe ".build_custom" do
    it "builds a key from a Vietnamese name and numbers a clash" do
      first = described_class.build_custom("Thủ quỹ")
      first.save!
      clashing = described_class.build_custom("Thu quy")

      expect(clashing).to be_valid
      expect(clashing.key).to eq("thu_quy_2")
      expect(first.position).to eq(70)
      expect(clashing.position).to eq(80)
      expect(clashing).not_to be_system
    end

    it "rejects a blank or duplicate name" do
      blank = described_class.build_custom("   ")
      duplicate = described_class.build_custom("kế toán")

      expect(blank).not_to be_valid
      expect(blank.errors[:name]).to be_present
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to be_present
    end

    it "falls back to a letter key when the name has no letters" do
      role = described_class.build_custom("123 !!!")

      expect(role).to be_valid
      expect(role.key).to eq("role_123")
    end
  end

  describe "#replace_grants!" do
    let(:role) { described_class.build_custom("Thủ quỹ").tap(&:save!) }

    it "stores manage together with read and drops anything left out" do
      role.replace_grants!([ %w[dealers manage], %w[audit_logs read], %w[not_a_screen manage], %w[users explode] ])

      expect(role.role_permissions.order(:resource, :ability).pluck(:resource, :ability)).to eq([
        %w[audit_logs read],
        %w[dealers manage],
        %w[dealers read]
      ])

      role.replace_grants!([ %w[audit_logs read] ])
      expect(role.reload.role_permissions.pluck(:resource, :ability)).to eq([ %w[audit_logs read] ])
    end

    it "does nothing when the grants are already those values" do
      role.replace_grants!([ %w[dealers read] ])
      ids = role.role_permissions.pluck(:id)

      role.replace_grants!([ %w[dealers read] ])

      expect(role.role_permissions.pluck(:id)).to eq(ids)
    end

    it "leaves the admin role's grants alone" do
      admin = described_class.find_by!(key: "admin")
      before = admin.role_permissions.count

      admin.replace_grants!([])

      expect(admin.role_permissions.count).to eq(before)
      expect(admin.granted?(:settings, :manage)).to be(true)
    end
  end

  describe "removal" do
    it "refuses a built-in role" do
      viewer = described_class.find_by!(key: "viewer")

      expect(viewer.destroy).to be(false)
      expect(viewer.errors[:base].join).to include("Không xoá được vai trò có sẵn")
      expect(described_class.where(key: "viewer")).to exist
    end

    it "refuses a role that still has users, and deletes one that does not" do
      assigned = described_class.build_custom("Ca đêm").tap(&:save!)
      create(:user, role: assigned.key)
      expect(assigned.destroy).to be(false)
      expect(assigned.errors[:base].join).to include("đang được gán")
      expect(described_class.where(key: assigned.key)).to exist

      empty = described_class.build_custom("Ca sáng").tap(&:save!)
      expect(empty.destroy).to be_truthy
      expect(described_class.where(key: empty.key)).not_to exist
    end
  end

  describe ".choices" do
    it "returns names and keys in display order" do
      described_class.build_custom("Ca chiều").save!

      expect(described_class.choices).to eq([
        [ "Quản trị", "admin" ],
        [ "Vận hành", "operator" ],
        [ "Chỉ xem", "viewer" ],
        [ "Kế toán", "ke_toan" ],
        [ "Đối soát", "doi_soat" ],
        [ "Vận hành kho", "van_hanh_kho" ],
        [ "Ca chiều", "ca_chieu" ]
      ])
    end
  end
end
