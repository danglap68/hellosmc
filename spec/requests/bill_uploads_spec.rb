require "rails_helper"

RSpec.describe "Manual bill upload" do
  include_context "accounting setup"

  before { sign_in create(:user, :operator) }

  it "accepts an image and queues OCR" do
    file = Rack::Test::UploadedFile.new(bill_fixture_path("normal_settlement.png"), "image/png")
    post admin_bill_uploads_path, params: { bill_upload_form: { image: file, dealer_id: dealer.id, card_type_key: "mb" } }

    bill_image = BillImage.last
    expect(response).to redirect_to(admin_reviews_path)
    expect(bill_image).to be_manual_upload
    expect(bill_image.mime_type).to eq("image/png")
    expect(bill_image.metadata).to include("dealer_id" => dealer.id, "card_type_key" => "mb")
    expect(AnalyzeBillImageJob).to have_been_enqueued.with(bill_image.id)
  end

  it "rejects non-images whatever the declared content type" do
    file = Rack::Test::UploadedFile.new(StringIO.new("%PDF-1.4 fake"), "image/jpeg", original_filename: "bill.jpg")
    post admin_bill_uploads_path, params: { bill_upload_form: { image: file, dealer_id: dealer.id } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(BillImage.count).to eq(0)
  end

  it "uses the uploaded dealer and card type when building" do
    file = Rack::Test::UploadedFile.new(bill_fixture_path("normal_settlement.jpg"), "image/jpeg")
    stub_vision(extraction_fixture("normal_settlement"))
    perform_enqueued_jobs do
      post admin_bill_uploads_path, params: { bill_upload_form: { image: file, dealer_id: dealer.id, card_type_key: "mb" } }
    end

    transaction = Transaction.sole
    expect(transaction.dealer).to eq(dealer)
    expect(transaction.card_type).to eq(mb_card)
    expect(transaction).to be_approved
  end
end
