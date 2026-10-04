require "rails_helper"

RSpec.describe "Fee rule management" do
  include_context "accounting setup"

  before { sign_in create(:user, :admin) }

  it "creates a rule from percentages and stores exact decimals" do
    visit new_admin_fee_rule_path
    select "Anh Trân", from: "Đại lý"
    select "Napas", from: "Loại thẻ"
    fill_in "fee_rule_base_fee_percent", with: "1,25"
    fill_in "fee_rule_dealer_percent", with: "1,40"
    fill_in "Ưu tiên", with: "50"
    click_button "Lưu"

    expect(page).to have_content("Đã tạo Quy tắc phí.")
    rule = FeeRule.order(:id).last
    expect(rule.base_fee_rate).to eq(BigDecimal("0.0125"))
    expect(rule.dealer_rate).to eq(BigDecimal("0.014"))
    expect(rule.specificity_level).to eq("dealer_card_type")
    expect(page).to have_content("1,25%")
    expect(AuditLog.where(action: "fee_rule.created", auditable: rule)).to exist
  end

  it "edits a rule with an audit trail" do
    visit edit_admin_fee_rule_path(default_rule)
    fill_in "fee_rule_base_fee_percent", with: "0,9"
    click_button "Lưu"

    expect(default_rule.reload.base_fee_rate).to eq(BigDecimal("0.009"))
    log = AuditLog.find_by!(action: "fee_rule.updated", auditable: default_rule)
    expect(log.before_data["base_fee_rate"]).to eq("0.0088")
    expect(log.after_data["base_fee_rate"]).to eq("0.009")
  end

  it "shows a Vietnamese error for overlapping rules" do
    visit new_admin_fee_rule_path
    fill_in "fee_rule_base_fee_percent", with: "0,95"
    click_button "Lưu"
    expect(page).to have_content("Trùng phạm vi")
  end

  it "refuses to delete a rule used by transactions" do
    Transactions::Builder.call(bill_image: analyzed_bill)
    visit admin_fee_rule_path(default_rule)
    click_button "Xoá"
    expect(page).to have_content("không thể xoá")
    expect(FeeRule.exists?(default_rule.id)).to be(true)
  end
end
