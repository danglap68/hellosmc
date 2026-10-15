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

  it "lists all transfer statuses by default and only filters when requested" do
    transfer
    other_transfers = %w[processing approved rejected failed].map { |status| create(:remitter_transfer, status: status) }
    get admin_remitter_transfers_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("##{transfer.id}", "Lập", I18n.t("remitter_transfers.reasons.code_missing"))
    other_transfers.each { |other| expect(response.body).to include(admin_remitter_transfer_path(other)) }

    get admin_remitter_transfers_path(queue: "needs_review")
    expect(response.body).to include(admin_remitter_transfer_path(transfer))
    other_transfers.each { |other| expect(response.body).not_to include(admin_remitter_transfer_path(other)) }

    get admin_remitter_transfers_path(queue: "invalid")
    other_transfers.each { |other| expect(response.body).to include(admin_remitter_transfer_path(other)) }
  end

  it "excludes automatic non-transfer images from every list and count, while preserving actual rejections" do
    transfer
    ignored = %w[not_a_transfer settlement_photo].map do |reason|
      create(:remitter_transfer, status: "rejected", review_reasons: [ reason ])
    end
    manual_rejection = create(:remitter_transfer, status: "rejected", reviewed_by: operator, review_reasons: [ "not_a_transfer" ])
    written = create(:remitter_transfer, status: "rejected", written_at: Time.current, review_reasons: [ "not_a_transfer" ])

    get admin_remitter_transfers_path
    ignored.each { |row| expect(response.body).not_to include(admin_remitter_transfer_path(row)) }
    expect(response.body).to include(admin_remitter_transfer_path(manual_rejection), admin_remitter_transfer_path(written))
    expect(Nokogiri::HTML(response.body).text).to include("Tất cả (3)")

    get admin_remitter_transfers_path(queue: "rejected")
    ignored.each { |row| expect(response.body).not_to include(admin_remitter_transfer_path(row)) }
    expect(response.body).to include(admin_remitter_transfer_path(manual_rejection))
  end

  it "opens the retained source message for an old non-transfer URL and prevents its approval" do
    transfer.update!(status: "rejected", review_reasons: [ "not_a_transfer" ])

    get admin_remitter_transfer_path(transfer)
    expect(response).to redirect_to(admin_message_path(transfer.telegram_message))
    follow_redirect!
    expect(response.body).not_to include("Translation missing")
    expect(response.body).not_to include(admin_remitter_transfer_path(transfer))
    expect(response.body).to include(admin_bill_image_path(transfer.bill_image), I18n.t("remitter_transfers.flash.non_transfer_image"))

    patch admin_remitter_transfer_path(transfer), params: { decision: "approve", remitter_transfer: { transfer_code: "TK01", amount_vnd: "1000000", remitter_id: lap.id } }
    expect(response).to redirect_to(admin_message_path(transfer.telegram_message))
    expect(transfer.reload).to be_rejected
    expect(WriteRemitterReportJob).not_to have_been_enqueued
  end

  it "shows the photo, caption and the review form" do
    get admin_remitter_transfer_path(transfer)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(admin_bill_image_path(transfer.bill_image), "chuyen tien", "TK01 · Thiên Kim GV · Chương")
  end

  it "does not display image-screening warnings or AI percentages for outgoing transfers, including legacy OCR metadata" do
    transfer.update!(review_reasons: %w[image_integrity_uncertain image_tampering_suspected code_missing])
    transfer.bill_image.update!(metadata: { "vision_pipeline" => {
      "validation_reason" => %w[image_integrity_uncertain image_tampering_suspected], "validation_result" => "unresolved" } })

    get admin_remitter_transfer_path(transfer)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("remitter_transfers.reasons.code_missing"))
    expect(response.body).not_to include(I18n.t("remitter_transfers.reasons.image_integrity_uncertain"),
      I18n.t("review_reasons.image_integrity_uncertain"), I18n.t("review_reasons.image_tampering_suspected"), 'data-testid="image-integrity-score"')
  end

  it "shows the reason an OCR disagreement was kept for manual review" do
    transfer.update!(review_reasons: [ "model_disagreement", "transfer_confirmation_conflict" ])
    get admin_remitter_transfers_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("remitter_transfers.reasons.model_disagreement"),
                                     I18n.t("remitter_transfers.reasons.transfer_confirmation_conflict"))
  end

  it "links to the original transfer and shows both matching reasons and its written sheet cell" do
    transfer.update!(amount_vnd: 14_815_636, transfer_code: "CH1", review_reasons: [ "possible_duplicate" ])
    original = create(:remitter_transfer, remitter: lap, amount_vnd: transfer.amount_vnd, transfer_code: "CH01",
                                         transferred_at: transfer.transferred_at - 9.seconds, status: "approved",
                                         written_at: Time.current, rd_sheet: "thu chi 1510", rd_cell: "I32")
    original_image = create(:bill_image, telegram_message: original.telegram_message)
    transfer.bill_image.update!(ocr_status: "duplicate", duplicate_of: original_image)

    get admin_remitter_transfer_path(transfer)

    expect(response).to have_http_status(:ok)
    warning = Nokogiri::HTML(response.body).at_css('[data-testid="transfer-duplicates"]')
    expect(warning.at_css("a")[:href]).to eq(admin_remitter_transfer_path(original))
    expect(warning.text).to include("##{original.id}", "Trùng ảnh gốc", "14.815.636", "thu chi 1510!I32",
                                    "Cùng người đi tiền", "10 phút")
    expect(warning.text).not_to include("Có thể trùng lệnh chuyển tiền khác")
    if ENV["SMC_DUPLICATE_PREVIEW"] == "1"
      path = Rails.root.join("tmp/diagnostics/transfer-duplicates#{ENV.fetch('TEST_ENV_NUMBER', '')}.html")
      FileUtils.mkdir_p(path.dirname)
      path.write(response.body)
    end
  end

  it "still explains a duplicate after the transfer has been manually approved" do
    transfer.update!(amount_vnd: 14_815_636, transfer_code: "CH1", status: "approved", review_reasons: [],
                     written_at: Time.current, rd_sheet: "thu chi 1510", rd_cell: "I34")
    original = create(:remitter_transfer, remitter: lap, amount_vnd: transfer.amount_vnd, transfer_code: "CH01",
                                         transferred_at: transfer.transferred_at - 9.seconds, status: "approved",
                                         written_at: Time.current, rd_sheet: "thu chi 1510", rd_cell: "I32")
    get admin_remitter_transfer_path(transfer)
    warning = Nokogiri::HTML(response.body).at_css('[data-testid="transfer-duplicates"]')
    expect(warning.at_css("a")[:href]).to eq(admin_remitter_transfer_path(original))
    expect(warning.text).to include("Cả hai lệnh đã ghi sheet", "thu chi 1510!I34", "thu chi 1510!I32")
  end

  it "links to the original bill when its duplicate has no original transfer" do
    original_image = create(:bill_image)
    transfer.bill_image.update!(ocr_status: "duplicate", duplicate_of: original_image)
    transfer.update!(review_reasons: [ "possible_duplicate" ])
    get admin_remitter_transfer_path(transfer)
    warning = Nokogiri::HTML(response.body).at_css('[data-testid="transfer-duplicates"]')
    expect(warning.text).to include("Trùng ảnh bill ##{original_image.id}")
    expect(warning.at_css("a")[:href]).to eq(admin_bill_image_path(original_image))
  end

  it "explains unavailable historical evidence instead of inventing a matching transfer" do
    transfer.update!(review_reasons: [ "possible_duplicate" ])
    get admin_remitter_transfer_path(transfer)
    warning = Nokogiri::HTML(response.body).at_css('[data-testid="transfer-duplicates"]')
    expect(warning.text).to include("hiện không tìm thấy lệnh hoặc ảnh gốc")
    expect(warning.css("a")).to be_empty
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

  it "stores the configured spelling when an admin approves with different zero padding" do
    patch admin_remitter_transfer_path(transfer), params: {
      decision: "approve", remitter_transfer: { transfer_code: "TK001", amount_vnd: "29.000.000" }
    }
    expect(transfer.reload).to be_approved
    expect(transfer.transfer_code).to eq("TK01")
    expect(transfer.merchant_dealer).to eq(MerchantDealer.find_by!(transfer_code: "TK01"))
  end

  it "lists approved and waiting transfers for the dashboard's selected accounting day" do
    transfer
    approved = create(:remitter_transfer, status: "approved", transferred_at: Time.current, amount_vnd: 10_000)
    old = create(:remitter_transfer, status: "approved", transferred_at: 1.day.ago, amount_vnd: 10_000)
    get admin_remitter_transfers_path(queue: "all", date_from: Time.zone.today.iso8601, date_to: Time.zone.today.iso8601)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("##{approved.id}", "##{transfer.id}")
    expect(response.body).not_to include(">##{old.id}</a>")
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

  it "offers a direct retry action on both the table and detail page" do
    [ admin_remitter_transfers_path, admin_remitter_transfer_path(transfer) ].each do |path|
      get path
      document = Nokogiri::HTML(response.body)
      form = document.at_css("form[action='#{retry_processing_admin_remitter_transfer_path(transfer)}']")
      expect(form).to be_present
      expect(form.at_css('button[aria-label="Thử lại"]')).to be_present
      expect(form["data-turbo-confirm"]).to include("Kiểm tra lại mã")
    end
  end

  it "retries the processing stage without immediately approving a transfer" do
    post retry_processing_admin_remitter_transfer_path(transfer), params: { lock_version: transfer.lock_version }
    expect(response).to redirect_to(admin_remitter_transfer_path(transfer))
    expect(transfer.reload).to be_processing
    expect(BuildRemitterTransferJob).to have_been_enqueued.with(transfer.id)
    expect(flash[:notice]).to include("Đang kiểm tra lại mã")
  end

  it "guards the OCR budget on direct retry requests and disables the button" do
    transfer.update!(review_reasons: [ "amount_missing" ])
    transfer.bill_image.update!(ocr_attempts: AppConfig.max_ocr_attempts)
    get admin_remitter_transfer_path(transfer)
    button = Nokogiri::HTML(response.body).at_css('button[aria-label="Thử lại"]')
    expect(button["disabled"]).to be_present
    post retry_processing_admin_remitter_transfer_path(transfer)
    expect(transfer.reload).to be_needs_review
    expect(flash[:alert]).to include("hết số lần đọc OCR")
    expect(AnalyzeBillImageJob).not_to have_been_enqueued
  end

  it "hides retry and refuses the endpoint for a viewer" do
    sign_in create(:user, :viewer)
    get admin_remitter_transfer_path(transfer)
    expect(Nokogiri::HTML(response.body).css('button[aria-label="Thử lại"]')).to be_empty
    post retry_processing_admin_remitter_transfer_path(transfer)
    expect(response).to have_http_status(:forbidden)
    expect(transfer.reload).to be_needs_review
  end
end
