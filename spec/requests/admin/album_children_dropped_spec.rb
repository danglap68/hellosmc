require "rails_helper"

# A settlement that printed everything: its child bills are dropped, so nothing
# about them is counted, summed or listed on the album pages.
RSpec.describe "Album with its child bills dropped" do
  include_context "accounting setup"

  before { sign_in create(:user, :admin) }

  let(:album) { create(:bill_album, telegram_chat: chat) }

  def image(documents, status: "completed")
    normalized = BillVision::Normalizer.call({ "documents" => documents }, provider: "openai", model: "gpt-test")
    create(:bill_image, bill_album: album, telegram_message: create(:telegram_message, telegram_chat: chat),
                        normalized_extraction: normalized, ocr_status: status)
  end

  def document(type, amount)
    base = extraction_fixture("normal_settlement")["documents"].first
    base.merge("document_type" => type, "total_amount_vnd" => amount)
  end

  # The settlement and two sale slips on ONE photo, plus a separate photo of a sale slip.
  let!(:photo) { image([ document("settlement", 77_678_000), document("child_receipt", 49_981_000), document("child_receipt", 27_697_000) ]) }
  let!(:slip) { image([ document("child_receipt", 12_000_000) ]) }

  before do
    BillAlbums::Reconciler.call(album)
    album.reload
  end

  it "stores nothing about the child bills" do
    expect(album.reconciliation_status).to eq("settlement_complete")
    expect(album).to have_attributes(child_count: 0, child_total_vnd: nil, match_difference_vnd: nil, transfer_amount_vnd: 77_678_000)
  end

  it "shows only the settlement's amount on the transaction page, and no child total or difference" do
    transaction = album.transactions.sole

    get admin_transaction_path(transaction)

    body = response.body
    expect(body).to include("77.678.000")
    expect(body).not_to include("49.981.000", "27.697.000", "12.000.000")
    expect(body).not_to include("Tổng bill con", "Chênh lệch")
    expect(body).to include("Bill con · bỏ qua")
  end

  it "shows the same on the album page" do
    get admin_bill_album_path(album)

    expect(response.body).to include("Bill con · bỏ qua", "settlement_complete").or include("Bill kết đầy đủ")
    expect(response.body).not_to include("Chênh lệch")
  end

  it "still shows the child bills of an album that was reconciled against them" do
    other = create(:bill_album, telegram_chat: chat)
    normalized = ->(docs) { BillVision::Normalizer.call({ "documents" => docs }, provider: "openai", model: "gpt-test") }
    create(:bill_image, bill_album: other, telegram_message: create(:telegram_message, telegram_chat: chat), ocr_status: "completed",
                        normalized_extraction: normalized.call([ document("child_receipt", 5_000_000) ]))
    create(:bill_image, bill_album: other, telegram_message: create(:telegram_message, telegram_chat: chat), ocr_status: "completed",
                        normalized_extraction: normalized.call([ document("settlement", 5_000_000).merge("lot_number" => nil) ]))
    BillAlbums::Reconciler.call(other)
    transaction = other.reload.transactions.sole

    get admin_transaction_path(transaction)

    expect(response.body).to include("Tổng bill con", "Chênh lệch", "5.000.000")
  end
end
