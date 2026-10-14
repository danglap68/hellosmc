require "rails_helper"

RSpec.describe "Dealer recipient QR import" do
  include RecipientQrFixtures
  let(:dealer) { create(:dealer, bank_bin: "970422", bank_account_number: "000123", bank_account_name: "PREVIOUS HOLDER") }

  before { sign_in create(:user, :admin) }

  it "suggests recipient fields without saving a dealer, bill, attachment or Telegram job" do
    original = dealer.attributes
    expect do
      post admin_dealer_bank_qrs_path, params: { qr_payload: recipient_qr_payload(holder: "NGUYEN VAN AN") }, as: :json
    end.not_to change { [ Dealer.count, BillImage.count, ActiveStorage::Blob.count, AuditLog.count ] }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("bank_bin" => "970415", "bank_account_number" => "0011001932418",
                                            "bank_account_name" => "NGUYEN VAN AN", "name_source" => "qr")
    expect(response.parsed_body.keys).not_to include("amount", "transfer_code", "auto_payment_qr")
    expect(dealer.reload.attributes).to eq(original)
    expect(DeliverPaymentQrJob).not_to have_been_enqueued
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "reads the printed holder name only when QR contains no name" do
    file = Rack::Test::UploadedFile.new(bill_fixture_path("normal_settlement.png"), "image/png")
    expect(PaymentQrs::RecipientNameReader).to receive(:call).with(image: an_instance_of(BillVision::Image), account_number: "0011001932418").and_return("NGUYEN VAN AN")
    post admin_dealer_bank_qrs_path, params: { qr_payload: recipient_qr_payload, image: file }
    expect(response.parsed_body).to include("bank_account_name" => "NGUYEN VAN AN", "name_source" => "image")
  end

  it "preserves the decoded account fields if name OCR is unavailable" do
    allow(PaymentQrs::RecipientNameReader).to receive(:call).and_raise(BillVision::TransientError, "timeout")
    file = Rack::Test::UploadedFile.new(bill_fixture_path("normal_settlement.png"), "image/png")
    post admin_dealer_bank_qrs_path, params: { qr_payload: recipient_qr_payload, image: file }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("bank_account_number" => "0011001932418", "bank_account_name" => nil)
    expect(response.parsed_body.fetch("message")).to include("bổ sung tên")
  end

  it "rejects non-images and oversized uploads before contacting OCR" do
    expect(PaymentQrs::RecipientNameReader).not_to receive(:call)
    [ Rack::Test::UploadedFile.new(StringIO.new("%PDF-fake"), "image/jpeg", original_filename: "qr.jpg"),
      Rack::Test::UploadedFile.new(StringIO.new("x" * (4.megabytes + 1)), "image/jpeg", original_filename: "qr.jpg") ].each do |file|
      post admin_dealer_bank_qrs_path, params: { qr_payload: recipient_qr_payload, image: file }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  it "rejects unknown / corrupted QR before reading a name" do
    expect(PaymentQrs::RecipientNameReader).not_to receive(:call)
    post admin_dealer_bank_qrs_path, params: { qr_payload: "https://example.test/pay" }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "requires dealer management permission" do
    sign_out :user
    sign_in create(:user, :viewer)
    post admin_dealer_bank_qrs_path, params: { qr_payload: recipient_qr_payload(holder: "NGUYEN VAN AN") }, as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
