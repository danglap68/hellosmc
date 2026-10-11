# Shared configuration resembling the customer's setup.
RSpec.shared_context "accounting setup" do
  let!(:normal_card) { create(:normal_card_type) }
  let!(:mb_card) { create(:mb_card_type) }
  let!(:napas_card) { create(:napas_card_type) }
  let!(:dealer) { create(:dealer, name: "Anh Trân", code: "TRAN") }
  let!(:chat) { create(:telegram_chat, active: true) }
  let!(:merchant) { create(:merchant, name: "001_ HỘ KINH DOANH THIÊN KIM GV", code: "001") }
  let!(:default_rule) { create(:fee_rule, base_fee_rate: BigDecimal("0.0088")) }
  let!(:mb_rule) { create(:fee_rule, card_type: mb_card, base_fee_rate: BigDecimal("0.011")) }
  # Phase 2: the dealer is the TID agent, resolved from the merchant name suffix.
  let!(:merchant_dealer_link) do
    create(:merchant_dealer, merchant: merchant, dealer: dealer, tid_key: "tid1",
           ds_sheet_anchor: "Thiên Kim GV", ds_header: "Anh Trân (tid1)", rd_agent_label: "Anh Trân")
  end

  # Workbook writing is covered separately; keep pipeline specs off Google and
  # off the "spreadsheet id not configured" error.
  before do
    allow(Workbook::HelloSmcWriter).to receive(:call).and_return(:skipped)
  end

  def analyzed_bill(extraction: "normal_settlement", caption: nil)
    message = create(:telegram_message, telegram_chat: chat, message_text: caption)
    create(:bill_image, :analyzed, telegram_message: message, extraction: extraction)
  end
end
