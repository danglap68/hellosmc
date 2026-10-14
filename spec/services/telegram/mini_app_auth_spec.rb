require "rails_helper"

RSpec.describe Telegram::MiniAppAuth do
  include_context "payment QR setup"

  it "accepts Telegram HMAC signatures including the signature field in the check string" do
    data = signed_payment_data("signature" => "telegram-third-party-signature")
    expect(described_class.call(data)).to include(user_id: 123456, start_param: "pqr_#{payment_qr.access_token}")
  end

  it "rejects future sessions, tampering, missing user IDs and oversized credentials" do
    [ signed_payment_data("auth_date" => 1.hour.from_now.to_i.to_s),
      signed_payment_data("user" => { id: "123456" }.to_json),
      signed_payment_data + "&hash=bad", "x" * 20_000 ].each do |data|
      expect { described_class.call(data) }.to raise_error(described_class::Invalid)
    end
  end
end
