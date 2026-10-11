require "rails_helper"

RSpec.describe "Admin bill images" do
  before { sign_in create(:user, :admin) }

  let!(:bill_image) { create(:bill_image) } # attached before any service stub

  it "streams the image from disk storage (development/test)" do
    get admin_bill_image_path(bill_image)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/jpeg")
  end

  # Production uses R2 (S3Service) and never loads DiskService; the controller
  # must not reference that constant (it raised NameError → 500 on prod).
  it "redirects to a presigned URL on object storage without touching DiskService" do
    s3_like = Class.new do
      def self.name = "ActiveStorage::Service::S3Service"
    end.new
    allow_any_instance_of(ActiveStorage::Blob).to receive(:service).and_return(s3_like)
    allow_any_instance_of(ActiveStorage::Blob).to receive(:url).and_return("https://r2.example.com/bill.jpg?sig=1")
    hide_const("ActiveStorage::Service::DiskService")

    get admin_bill_image_path(bill_image)

    expect(response).to redirect_to("https://r2.example.com/bill.jpg?sig=1")
  end
end
