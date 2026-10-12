require "rails_helper"

# The album of a calculator, a payment QR code (sent before, so a duplicate) and one
# photo holding the settlement with its sale slips: one transaction, from the settlement.
RSpec.describe "Album with photos that are not bills" do
  include_context "accounting setup"

  before { sign_in create(:user, :admin) }

  def document(type, amount)
    extraction_fixture("normal_settlement")["documents"].first.merge("document_type" => type, "total_amount_vnd" => amount)
  end

    let(:album) { create(:bill_album, telegram_chat: chat) }
    let(:unknown) { BillVision::Normalizer.call({ "documents" => [] }, provider: "openai", model: "gpt-test") }

    def stored_image(album, normalized, **attrs)
      create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                          normalized_extraction: normalized, **attrs)
    end

    before do
      calculator = stored_image(album, unknown, ocr_status: "needs_review")
      first_qr = stored_image(create(:bill_album, telegram_chat: chat), unknown, ocr_status: "needs_review")
      qr_again = stored_image(album, nil, ocr_status: "duplicate", duplicate_of: first_qr)
      settlement = BillVision::Normalizer.call({ "documents" => [ document("settlement", 77_678_000), document("child_receipt", 49_981_000),
                                                                 document("child_receipt", 27_697_000) ] }, provider: "openai", model: "gpt-test")
      @photo = stored_image(album, settlement, ocr_status: "completed")
      @calculator, @qr_again = calculator, qr_again
      BillAlbums::Reconciler.call(album)
      album.reload
    end

    it "creates one transaction, from the settlement photo, and nothing else" do
      expect(album.status).to eq("reconciled")
      expect(album.transactions.count).to eq(1)
      expect(album.transactions.sole).to have_attributes(bill_image_id: @photo.id, transaction_amount_vnd: 77_678_000)
      expect(Transaction.where(bill_image_id: [ @calculator.id, @qr_again.id ])).to be_empty
    end

    it "labels the settlement 'Bill kết' and the others 'Bỏ qua', with no review flag on a calculator" do
      get admin_bill_album_path(album)

      body = Nokogiri::HTML(response.body)
      cards = body.css(".col-6 .card-body").map { |card| card.css(".badge").map { |badge| badge.text.strip } }
      expect(cards).to contain_exactly([ "Bỏ qua" ], [ "Bỏ qua", "Trùng ảnh" ], [ "Bill kết", "Hoàn tất" ])
      expect(response.body).not_to include("Hình chuyển tiền", "Cần kiểm tra")
    end

    it "uses the same labels on the transaction page" do
      get admin_transaction_path(album.transactions.sole)

      expect(response.body).to include("Bill kết", "Bỏ qua")
      expect(response.body).not_to include("Hình chuyển tiền")
    end
end
