require "rails_helper"

RSpec.describe User do
  it { is_expected.to validate_presence_of(:email) }

  it "only accepts known roles" do
    user = build(:user, role: "superuser")
    expect(user).not_to be_valid
    expect(user.errors[:role]).to be_present
  end

  it "requires a strong enough password" do
    user = build(:user, password: "short", password_confirmation: "short")
    expect(user).not_to be_valid
  end

  describe "#active_for_authentication?" do
    it "is true for active users" do
      expect(build(:user).active_for_authentication?).to be(true)
    end

    it "is false for inactive users" do
      user = build(:user, :inactive)
      expect(user.active_for_authentication?).to be(false)
      expect(user.inactive_message).to eq(:account_inactive)
    end
  end

  describe "#display_name" do
    it "falls back to the email" do
      expect(build(:user, name: nil, email: "a@b.vn").display_name).to eq("a@b.vn")
    end
  end
end
