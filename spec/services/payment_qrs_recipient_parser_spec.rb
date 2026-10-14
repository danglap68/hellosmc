require "rails_helper"

RSpec.describe PaymentQrs::RecipientParser do
  include RecipientQrFixtures

  it "reads a static VietQR recipient while preserving leading zeroes and ignoring fixed amount / memo" do
    fields = described_class.call(recipient_qr_payload)
    expect(fields).to eq("bank_bin" => "970415", "bank_name" => "VietinBank",
                         "bank_account_number" => "0011001932418", "bank_account_name" => nil, "name_source" => nil)
  end

  it "reads UTF-8 account holder names using byte lengths" do
    fields = described_class.call(recipient_qr_payload(holder: "NGUYỄN VĂN AN"))
    expect(fields).to include("bank_account_name" => "NGUYỄN VĂN AN", "name_source" => "qr")
  end

  it "does not mistake a generic QR label for a recipient name" do
    expect(described_class.call(recipient_qr_payload(holder: "VIETQR"))["bank_account_name"]).to be_nil
  end

  it "rejects altered CRCs, duplicate fields, invalid lengths and unrelated payment QR formats" do
    corrupted = recipient_qr_payload.dup
    corrupted[-1] = corrupted[-1] == "0" ? "1" : "0"
    invalid = [ corrupted, recipient_qr_payload(extra: "000201"),
                recipient_qr_payload.sub("3857", "3899"), "https://example.test/pay", "x" * 3000,
                recipient_qr_payload(service: "QRIBFTTC"), recipient_qr_payload(bank: "123456"),
                recipient_qr_payload(currency: "840"), recipient_qr_payload(account: "123/45") ]
    invalid.each { |payload| expect { described_class.call(payload) }.to raise_error(PaymentQrs::Error) }
  end
end
