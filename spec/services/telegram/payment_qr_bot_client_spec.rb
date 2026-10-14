require "rails_helper"

RSpec.describe Telegram::BotClient, "payment QR transport" do
  it "uploads PNG bytes as multipart and serializes the inline keyboard" do
    png = PaymentQrs::Vietqr.png(PaymentQrs::Vietqr.payload(bank_bin: "970422", account_number: "000123", amount: 100, memo: "AS2"))
    stub = stub_request(:post, "https://api.telegram.org/bot123456:TEST-TOKEN/sendPhoto")
      .with { |request| request.headers["Content-Type"].include?("multipart/form-data") && request.body.include?("payment-qr.png") && request.body.include?(png) }
      .to_return(body: { ok: true, result: { message_id: 123 } }.to_json, headers: { "Content-Type" => "application/json" })
    result = described_class.new.send_photo(png: png, chat_id: -123, caption: "AS2")
    expect(result.fetch("message_id")).to eq(123)
    expect(stub).to have_been_requested.once
  end
end
