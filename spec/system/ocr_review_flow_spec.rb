require "rails_helper"

RSpec.describe "OCR review flow" do
  include_context "accounting setup"

  let(:operator) { create(:user, :operator) }
  let!(:transaction) { Transactions::Builder.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole }

  before { sign_in operator }

  it "lets an operator correct and approve a low-confidence bill" do
    visit admin_reviews_path
    expect(page).to have_content("Kiểm tra OCR")
    expect(page).to have_content("Tổng tiền không rõ")

    click_link "Kiểm tra", href: admin_review_path(transaction)
    expect(page).to have_content("Thông tin cần xác nhận")
    expect(page).to have_content("OCR đọc được: 11.445.000 ₫")

    fill_in "Số tiền giao dịch", with: "11.445.000"
    select "001_ HỘ KINH DOANH THIÊN KIM GV [001]", from: "Hộ kinh doanh"
    fill_in "note", with: "Đã đối chiếu với bill giấy"
    click_button "Lưu & duyệt"

    expect(page).to have_content("Đã duyệt giao dịch.")
    transaction.reload
    expect(transaction).to be_approved
    expect(transaction.approved_by).to eq(operator)
    expect(transaction.amount_after_base_fee_vnd).to eq(11_344_284)

    visit admin_transactions_path(status: "approved")
    expect(page).to have_content("11.445.000 ₫")
  end

  it "saves a draft without approving" do
    visit admin_review_path(transaction)
    fill_in "Số lô", with: "000999"
    click_button "Lưu nháp"

    expect(page).to have_content("Đã lưu nháp.")
    expect(transaction.reload.lot_number).to eq("000999")
    expect(transaction).to be_needs_review
  end

  it "puts a bill on hold and then rejects it" do
    visit admin_review_path(transaction)
    click_button "Tạm giữ"
    expect(transaction.reload).to be_hold

    visit admin_review_path(transaction)
    click_button "Từ chối"
    expect(transaction.reload).to be_rejected
  end

  it "shows validation errors when approval is impossible" do
    visit admin_review_path(transaction)
    select "— Chọn —", from: "Hộ kinh doanh"
    click_button "Lưu & duyệt"

    expect(page).to have_content("Hộ kinh doanh")
    expect(page).to have_css(".alert-danger")
    expect(transaction.reload).to be_needs_review
  end

  it "refuses a decision taken on a stale page" do
    visit admin_review_path(transaction)
    Transactions::StatusUpdater.call(transaction: Transaction.find(transaction.id), actor: operator, action: "hold")
    click_button "Lưu & duyệt"

    expect(page).to have_content("vừa được người khác cập nhật")
    expect(transaction.reload).to be_hold
  end
end
