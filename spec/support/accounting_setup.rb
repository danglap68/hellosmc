# Shared configuration resembling the customer's setup.
RSpec.shared_context "accounting setup" do
  let!(:normal_card) { create(:normal_card_type) }
  let!(:mb_card) { create(:mb_card_type) }
  let!(:napas_card) { create(:napas_card_type) }
  let!(:dealer) { create(:dealer, name: "Anh Trân", code: "TRAN") }
  let!(:chat) { create(:telegram_chat, dealer: dealer, active: true) }
  let!(:merchant) { create(:merchant, name: "001_ HỘ KINH DOANH THIÊN KIM GV", code: "001", dealer: dealer) }
  let!(:default_rule) { create(:fee_rule, base_fee_rate: BigDecimal("0.0088")) }
  let!(:mb_rule) { create(:fee_rule, card_type: mb_card, base_fee_rate: BigDecimal("0.011")) }

  def analyzed_bill(extraction: "normal_settlement", caption: nil)
    message = create(:telegram_message, telegram_chat: chat, message_text: caption)
    create(:bill_image, :analyzed, telegram_message: message, extraction: extraction)
  end
end
