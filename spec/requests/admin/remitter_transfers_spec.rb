require "rails_helper"

RSpec.describe "Admin remitter transfers" do
  let(:operator) { create(:user, :operator) }
  # Workbook::Seed (in before) already creates Lập; excel_key is unique.
  let(:lap) { Remitter.find_by!(excel_key: "LẬP") }
  let(:transfer) do
    message = create(:telegram_message, message_text: "chuyen tien", sender_name: "Dang Van Lap")
    image = create(:bill_image, :analyzed, extraction: "transfer", telegram_message: message)
    create(:remitter_transfer, telegram_message: message, bill_image: image, remitter: lap, status: "needs_review",
                               amount_vnd: 29_274_000, review_reasons: [ "code_missing" ])
  end

  before do
    Workbook::Seed.call
    sign_in operator
  end

  it "lists the transfers waiting for review with their reasons" do
    transfer
    get admin_remitter_transfers_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("##{transfer.id}", "Lập", "Tin nhắn không có mã chuyển tiền")
  end

  it "shows the photo, caption and the review form" do
    get admin_remitter_transfer_path(transfer)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(admin_bill_image_path(transfer.bill_image), "chuyen tien", "TK01 · Thiên Kim GV · Chương")
  end

  it "approves with a corrected code and amount, then queues the sheet write" do
    patch admin_remitter_transfer_path(transfer), params: {
      decision: "approve", lock_version: transfer.lock_version,
      remitter_transfer: { transfer_code: "TK01", amount_vnd: "29.000.000", remitter_id: lap.id }
    }

    transfer.reload
    expect(transfer).to be_approved
    expect(transfer).to have_attributes(transfer_code: "TK01", amount_vnd: 29_000_000, code_source: "manual",
                                        reviewed_by: operator, review_reasons: [])
    expect(transfer.dealer.name).to eq("Chương")
    expect(WriteRemitterReportJob).to have_been_enqueued.with(transfer.id)
    expect(AuditLog.where(action: "remitter_transfer.approved", auditable: transfer)).to exist
  end

  it "refuses to approve without a valid code" do
    patch admin_remitter_transfer_path(transfer), params: { decision: "approve", remitter_transfer: { transfer_code: "" } }

    expect(transfer.reload).to be_needs_review
    expect(flash[:alert]).to include("Mã chuyển tiền không hợp lệ")
  end

  it "refuses an amount that is not whole VND instead of guessing" do
    %w[29.5 -100 29tr].each do |amount|
      patch admin_remitter_transfer_path(transfer), params: {
        decision: "approve", remitter_transfer: { transfer_code: "TK01", amount_vnd: amount, remitter_id: lap.id }
      }
      expect(transfer.reload).to be_needs_review, amount
      expect(flash[:alert]).to include("Số tiền không hợp lệ")
    end
  end

  it "rejects a transfer" do
    patch admin_remitter_transfer_path(transfer), params: { decision: "reject", lock_version: transfer.lock_version }

    expect(transfer.reload).to be_rejected
    expect(WriteRemitterReportJob).not_to have_been_enqueued
  end

  it "never changes a transfer already written to the sheet" do
    transfer.update!(status: "approved", written_at: Time.current, rd_sheet: "thu chi 1010", rd_cell: "J31")

    patch admin_remitter_transfer_path(transfer), params: { decision: "reject" }

    expect(transfer.reload).to be_approved
    expect(flash[:alert]).to include("Đã ghi sheet")
  end

  it "queues the write again for an approved transfer that is not in the sheet" do
    link = RemitterTransfers::Codes.merchant_dealer_for("TK01")
    transfer.update!(status: "approved", transfer_code: "TK01", merchant_dealer: link, merchant: link.merchant,
                     metadata: { "write_issue" => "rd_sheet_missing" })

    post write_admin_remitter_transfer_path(transfer)

    expect(WriteRemitterReportJob).to have_been_enqueued.with(transfer.id)
  end

  it "lets a viewer look but not decide" do
    sign_in create(:user, :viewer)
    get admin_remitter_transfer_path(transfer)
    expect(response).to have_http_status(:ok)

    patch admin_remitter_transfer_path(transfer), params: { decision: "reject" }
    expect(response).to have_http_status(:forbidden)
    expect(transfer.reload).to be_needs_review
  end
end
