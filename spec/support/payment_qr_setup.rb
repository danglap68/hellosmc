RSpec.shared_context "payment QR setup" do
  let(:payment_dealer) do
    create(:dealer, bank_bin: "970422", bank_account_number: "076802960001",
           bank_account_name: "NGUYEN VAN HIEU", auto_payment_qr: true)
  end
  let(:payment_transaction) { create(:transaction, :approved, dealer: payment_dealer, dealer_amount_vnd: 9_860_000) }
  let!(:payment_link) do
    create(:merchant_dealer, merchant: payment_transaction.merchant, dealer: payment_dealer,
           transfer_code: "AS2", tid_key: "tid2")
  end
  let(:payment_qr) { PaymentQrs::Prepare.call(payment_transaction) }

  def enable_payment_telegram
    AppSetting.create!(key: "payment_qr_telegram_enabled", value: "true")
    AppSetting.create!(key: "payment_qr_bot_username", value: "smc_test_bot")
    payment_transaction.telegram_message.telegram_chat.update!(payment_qr_confirmer_ids: [ 123456 ])
  end

  def signed_payment_data(overrides = {})
    fields = { "auth_date" => Time.current.to_i.to_s,
               "user" => { id: 123456, first_name: "Tester" }.to_json,
               "start_param" => "pqr_#{payment_qr.access_token}" }.merge(overrides)
    secret = OpenSSL::HMAC.digest("SHA256", "WebAppData", AppConfig.telegram_bot_token)
    fields["hash"] = OpenSSL::HMAC.hexdigest("SHA256", secret, fields.sort.map { |key, value| "#{key}=#{value}" }.join("\n"))
    URI.encode_www_form(fields)
  end
end
