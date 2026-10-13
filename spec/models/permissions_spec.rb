require "rails_helper"

RSpec.describe Permissions do
  let(:operator_manage) { %i[transactions reviews remitter_transfers bill_uploads excel_exports] }
  let(:operator_read) do
    %i[dashboard messages bill_images bill_albums dealers telegram_chats merchants fee_rules remitters card_types audit_logs]
  end
  let(:viewer_read) { %i[dashboard transactions remitter_transfers bill_images bill_albums excel_exports] }

  it "lists each resource once, in a group" do
    listed = described_class::GROUPS.flat_map { |group| group[:resources] }

    expect(listed).to eq(listed.uniq)
    expect(listed).to match_array(described_class::RESOURCES)
  end

  it "covers every permission declared by an admin controller" do
    declared = Rails.root.glob("app/controllers/admin/**/*.rb").flat_map { |path|
      File.read(path).scan(/permission :(\w+)/).flatten
    }.uniq

    expect(declared).to include("dashboard", "roles", "messages")
    expect(described_class::RESOURCES.map(&:to_s)).to include(*declared)
  end

  it "only uses known resources in the starting grants" do
    described_class::DEFAULT_GRANTS.each_value do |rules|
      next if rules == :all

      expect(described_class::RESOURCES).to include(*(rules[:manage] + rules[:read]))
    end
  end

  it "has a Vietnamese label for every resource and group" do
    described_class::GROUPS.each do |group|
      expect(I18n.t("roles.groups.#{group[:key]}")).not_to include("translation missing")
      group[:resources].each do |resource|
        expect(I18n.t("roles.resources.#{resource}.name")).not_to include("translation missing")
        expect(I18n.t("roles.resources.#{resource}.hint")).not_to include("translation missing")
      end
    end
  end

  describe ".allowed?" do
    it "denies a missing or inactive user" do
      expect(described_class.allowed?(nil, :read, :dashboard)).to be(false)
      expect(described_class.allowed?(build(:user, :admin, :inactive), :manage, :users)).to be(false)
    end

    it "lets an admin read and manage every resource, even with no rows stored" do
      Role.find_by!(key: "admin").role_permissions.delete_all
      admin = create(:user, :admin)

      described_class::RESOURCES.each do |resource|
        expect(admin.can?(:read, resource)).to be(true), resource.to_s
        expect(admin.can?(:manage, resource)).to be(true), resource.to_s
      end
    end

    it "gives an operator the starting work and read-only configuration" do
      operator = create(:user, :operator)

      described_class::RESOURCES.each do |resource|
        expect(operator.can?(:manage, resource)).to eq(operator_manage.include?(resource)), "manage #{resource}"
        expect(operator.can?(:read, resource)).to eq(operator_manage.include?(resource) || operator_read.include?(resource)), "read #{resource}"
      end
    end

    it "gives a viewer read-only access to the report screens" do
      viewer = create(:user, :viewer)

      described_class::RESOURCES.each do |resource|
        expect(viewer.can?(:manage, resource)).to be(false), "manage #{resource}"
        expect(viewer.can?(:read, resource)).to eq(viewer_read.include?(resource)), "read #{resource}"
      end
    end

    it "treats manage as including read, and read as not including manage" do
      role = Role.build_custom("Thủ quỹ")
      role.save!
      role.role_permissions.create!(resource: "dealers", ability: "manage")
      user = create(:user, role: role.key)

      expect(user.can?(:manage, :dealers)).to be(true)
      expect(user.can?(:read, :dealers)).to be(true)
      expect(user.can?(:manage, :users)).to be(false)
      expect(user.can?(:read, :users)).to be(false)
    end

    it "denies an unknown resource, an unknown ability, and a role that does not exist" do
      operator = create(:user, :operator)

      expect(operator.can?(:read, :not_a_screen)).to be(false)
      expect(operator.can?(:destroy, :transactions)).to be(false)
      expect(described_class.allow_snapshot?(described_class.snapshot_for("missing"), :read, :dashboard)).to be(false)
    end

    it "keeps a snapshot for the request and drops it when the user is reloaded" do
      operator = create(:user, :operator)
      expect(operator.can?(:manage, :transactions)).to be(true)

      Role.find_by!(key: "operator").role_permissions.where(resource: "transactions", ability: "manage").delete_all
      expect(operator.can?(:manage, :transactions)).to be(true)

      expect(operator.reload.can?(:manage, :transactions)).to be(false)
      expect(operator.can?(:read, :transactions)).to be(true)
    end
  end
end
