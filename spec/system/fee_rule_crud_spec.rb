require "rails_helper"

RSpec.describe "Fee rule management" do
  include_context "accounting setup"

  before { sign_in create(:user, :admin) }

  it "suggests rate placeholders from the selected card type" do
    visit new_admin_fee_rule_path

    expect(page).to have_field("fee_rule_base_fee_percent", placeholder: "1,21")
    expect(page).to have_field("fee_rule_dealer_percent", placeholder: "1,4")
    expect(page).to have_unchecked_field("MB")
    expect(page).to have_button("Mọi loại thẻ")
    expect(page).to have_button("Mọi hộ kinh doanh")
    expect(page).to have_css("input[data-key='mb']")
    expect(page).to have_css("input[data-key='napas']")

    visit edit_admin_fee_rule_path(mb_rule)
    expect(page).to have_button("MB")
    expect(page).to have_field("fee_rule_base_fee_percent", placeholder: "1,21")
    expect(page).to have_field("fee_rule_card_base_fee_percent", placeholder: "0,88")
    expect(page).to have_field("fee_rule_dealer_percent", placeholder: "1,2")
  end

  it "stores one rule for MB and Napas and suggests their placeholders" do
    visit new_admin_fee_rule_path
    check "MB"
    check "Napas"
    fill_in "fee_rule_base_fee_percent", with: "0,88"
    fill_in "fee_rule_dealer_percent", with: "1,2"
    fill_in "Ưu tiên", with: "40"
    click_button "Lưu"

    rule = FeeRule.order(:id).last
    expect(rule.card_type_ids).to contain_exactly(mb_card.id, napas_card.id)
    expect(page).to have_content("MB")
    expect(page).to have_content("Napas")

    visit edit_admin_fee_rule_path(rule)
    expect(page).to have_button("MB, Napas")
    expect(page).to have_field("fee_rule_base_fee_percent", placeholder: "1,21")
    expect(page).to have_field("fee_rule_card_base_fee_percent", placeholder: "0,88")
    expect(page).to have_field("fee_rule_dealer_percent", placeholder: "1,2")
  end

  it "stores households and card types on one rule with a card base fee" do
    second = create(:merchant, name: "TRAN3 Trân 3", code: "TRAN3", dealer: dealer)
    visit new_admin_fee_rule_path
    check "#{merchant.name} [#{merchant.code}]"
    check "#{second.name} [#{second.code}]"
    check "Napas"
    fill_in "fee_rule_base_fee_percent", with: "1,21"
    fill_in "fee_rule_card_base_fee_percent", with: "0,88"
    fill_in "fee_rule_dealer_percent", with: "1,2"
    fill_in "Ưu tiên", with: "40"
    click_button "Lưu"

    rule = FeeRule.order(:id).last
    expect(rule.merchant_ids).to contain_exactly(merchant.id, second.id)
    expect(rule.card_type_ids).to contain_exactly(napas_card.id)
    expect(rule.base_fee_rate).to eq(BigDecimal("0.0121"))
    expect(rule.card_base_fee_rate).to eq(BigDecimal("0.0088"))
    expect(rule.dealer_rate).to eq(BigDecimal("0.012"))
  end

  it "stores one rule for several households" do
    second = create(:merchant, name: "TRAN3 Trân 3", code: "TRAN3", dealer: dealer)
    visit new_admin_fee_rule_path
    check "#{merchant.name} [#{merchant.code}]"
    check "#{second.name} [#{second.code}]"
    fill_in "fee_rule_base_fee_percent", with: "1,21"
    fill_in "fee_rule_dealer_percent", with: "1,40"
    click_button "Lưu"

    rule = FeeRule.order(:id).last
    expect(rule.merchant_ids).to contain_exactly(merchant.id, second.id)
    expect(page).to have_content(merchant.name)
    expect(page).to have_content(second.name)
  end

  it "creates a rule from percentages and stores exact decimals" do
    visit new_admin_fee_rule_path
    select "Anh Trân", from: "Đại lý"
    check "Napas"
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
