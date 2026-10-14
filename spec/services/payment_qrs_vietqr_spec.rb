require "rails_helper"

RSpec.describe PaymentQrs::Vietqr do
  # NAPAS reference account-transfer example uses free text. Production memo
  # is restricted to a configured transfer code; assert the same field layout
  # and reference CRC independently of that stricter input validation.
  it "matches the NAPAS reference CRC" do
    reference = "00020101021238570010A00000072701270006970415011300110019324180208QRIBFTTA530370454061200005802VN62170813ung ho lu lut6304"
    expect(described_class.send(:crc16, reference)).to eq("C15C")
  end

  it "encodes VietQR fields, leading zeroes, VND, amount and memo exactly" do
    payload = described_class.payload(bank_bin: "970415", account_number: "0011001932418", amount: 120000, memo: "AS2")
    expect(payload).to start_with("00020101021238570010A00000072701270006970415011300110019324180208QRIBFTTA530370454061200005802VN62070803AS26304")
    png = described_class.png(payload)
    expect(png.bytes.first(8)).to eq([ 137, 80, 78, 71, 13, 10, 26, 10 ])
    expect(ChunkyPNG::Image.from_blob(png).width).to eq(480)
  end

  it "refuses unknown bank BINs and invalid recipient accounts" do
    expect { described_class.payload(bank_bin: "123456", account_number: "123", amount: 100, memo: "AS2") }.to raise_error(ArgumentError)
    expect { described_class.payload(bank_bin: "970422", account_number: "123/45", amount: 100, memo: "AS2") }.to raise_error(ArgumentError)
  end

  it "keeps recipient banks whose apps are not marked as supporting VietQR scanning" do
    bank = PaymentQrs::Banks.all.find { |entry| entry["bin"] == "458761" }
    expect(bank).to include("shortName" => "HSBC", "transferSupported" => 0)
    payload = described_class.payload(bank_bin: bank.fetch("bin"), account_number: "000123456", amount: 120000, memo: "AS2")
    expect(payload).to include("0006458761", "0109000123456")
  end
end
