require "rails_helper"

RSpec.describe "Role restrictions" do
  include_context "accounting setup"

  let(:transaction) { create(:transaction, dealer: dealer, merchant: merchant, card_type: normal_card) }

  context "as a viewer" do
    before { sign_in create(:user, :viewer) }

    it "can read the dashboard and transactions" do
      get admin_root_path
      expect(response).to have_http_status(:ok)
      get admin_transactions_path
      expect(response).to have_http_status(:ok)
      get admin_transaction_path(transaction)
      expect(response).to have_http_status(:ok)
    end

    it "cannot approve, review or configure" do
      post approve_admin_transaction_path(transaction)
      expect(response).to have_http_status(:forbidden)
      get admin_reviews_path
      expect(response).to have_http_status(:forbidden)
      get admin_fee_rules_path
      expect(response).to have_http_status(:forbidden)
      get admin_users_path
      expect(response).to have_http_status(:forbidden)
      expect(transaction.reload).to be_needs_review
    end
  end

  context "as an operator" do
    before { sign_in create(:user, :operator) }

    it "can work the review queue and transactions" do
      get admin_reviews_path
      expect(response).to have_http_status(:ok)
      post hold_admin_transaction_path(transaction)
      expect(transaction.reload).to be_hold
    end

    it "can read but not change configuration" do
      get admin_fee_rules_path
      expect(response).to have_http_status(:ok)
      get new_admin_fee_rule_path
      expect(response).to have_http_status(:forbidden)
      post admin_dealers_path, params: { dealer: { name: "X", code: "X" } }
      expect(response).to have_http_status(:forbidden)
      expect(Dealer.where(code: "X")).not_to exist
    end

    it "cannot manage users or settings" do
      get admin_users_path
      expect(response).to have_http_status(:forbidden)
      get admin_settings_path
      expect(response).to have_http_status(:forbidden)
    end
  end

  context "as an admin" do
    before { sign_in create(:user, :admin) }

    it "can manage users and settings" do
      get admin_users_path
      expect(response).to have_http_status(:ok)
      get admin_settings_path
      expect(response).to have_http_status(:ok)
    end
  end
end
