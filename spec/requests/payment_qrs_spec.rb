require "rails_helper"

RSpec.describe "Payment QR admin and Telegram Mini App" do
  include_context "payment QR setup"

  context "admin" do
    before { sign_in create(:user, :admin) }

    it "lets an admin prepare, edit and download a QR while Telegram remains off" do
      post admin_dealer_payment_qrs_path, params: { transaction_id: payment_transaction.id }
      qr = DealerPaymentQr.last
      get admin_dealer_payment_qr_path(qr)
      expect(response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
      expect(response.body).to include("Chưa gửi thông tin", "Xác nhận &amp; tạo QR", "9860000")
      patch admin_dealer_payment_qr_path(qr), params: { decision: "confirm", amount: "79197000", version: qr.lock_version }
      expect(qr.reload.transfer_amount_vnd).to eq(79_197_000)
      get admin_dealer_payment_qr_path(qr, format: :png)
      expect(response.media_type).to eq("image/png")
      expect(response.headers["Cache-Control"]).to include("no-store")
      payment_dealer.update!(bank_account_number: "000123")
      get admin_dealer_payment_qr_path(qr, format: :png)
      expect(response).to have_http_status(:conflict)
    end

    it "exposes bank profile inputs and preserves account leading zeroes" do
      get edit_admin_dealer_path(payment_dealer)
      expect(response.body).to include("dealer[bank_bin]", "dealer[bank_account_number]", "dealer[auto_payment_qr]")
      expect(Nokogiri::HTML(response.body).at_css('option[value="458761"]').text).to include("HSBC")
      patch admin_dealer_path(payment_dealer), params: { dealer: { bank_account_number: "000123456" } }
      expect(payment_dealer.reload.bank_account_number).to eq("000123456")
    end
  end

  it "does not let a viewer confirm payouts" do
    sign_in create(:user, :viewer)
    patch admin_dealer_payment_qr_path(payment_qr), params: { decision: "confirm", amount: "100", version: 0 }
    expect(response).to have_http_status(:forbidden)
    expect(payment_qr.reload).to be_pending
  end

  it "serves only a public shell with no recipient or amount data" do
    payment_qr
    get telegram_payment_qr_path
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("076802960001", "NGUYEN VAN HIEU", "9860000")
    expect(response.headers["X-Frame-Options"]).to be_nil
    expect(response.headers["Content-Security-Policy"]).to eq("frame-ancestors 'self' https://web.telegram.org")
  end

  it "rejects Telegram access while the trial switch is off" do
    post "/telegram/payment-qr/context", params: { init_data: signed_payment_data }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  context "enabled Telegram flow" do
    before { enable_payment_telegram }

    it "accepts signed authorized users and records their payout correction" do
      signed = signed_payment_data
      post "/telegram/payment-qr/context", params: { init_data: signed }, as: :json
      expect(response).to have_http_status(:ok)
      version = response.parsed_body.fetch("version")
      post "/telegram/payment-qr/decide", params: { init_data: signed, decision: "confirm", amount: "79197000", version: version }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("transfer_amount_vnd" => 79_197_000, "status" => "confirmed")
      expect(payment_qr.reload.confirmed_by_telegram_id).to eq(123456)
      expect(payment_transaction.reload.dealer_amount_vnd).to eq(9_860_000)
    end

    it "rejects tampered, expired, duplicate-key, unlisted and wrong request credentials" do
      invalid = [ signed_payment_data + "&user=%7B%22id%22%3A123456%7D",
                  signed_payment_data("auth_date" => 2.hours.ago.to_i.to_s),
                  signed_payment_data("user" => { id: 999 }.to_json),
                  signed_payment_data("start_param" => "pqr_#{'x' * 32}"),
                  signed_payment_data.sub("Tester", "Someone") ]
      invalid.each do |init_data|
        post "/telegram/payment-qr/context", params: { init_data: init_data }, as: :json
        expect(response).to have_http_status(:forbidden)
        expect(response.body).not_to include("076802960001")
      end
      expect(payment_qr.reload).to be_pending
    end

    it "rejects an expired token after admin refresh and revoked group access" do
      signed = signed_payment_data
      PaymentQrs::Prepare.call(payment_transaction, refresh: true)
      post "/telegram/payment-qr/context", params: { init_data: signed }, as: :json
      expect(response).to have_http_status(:forbidden)
      payment_transaction.telegram_message.telegram_chat.update!(payment_qr_confirmer_ids: [])
      post "/telegram/payment-qr/context", params: { init_data: signed_payment_data }, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
