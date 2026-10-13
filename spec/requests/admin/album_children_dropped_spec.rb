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

  it "shows the settlement photo alone on the transaction page: no album strip, no child total, no other photo" do
    transaction = album.transactions.sole

    get admin_transaction_path(transaction)

    body = response.body
    expect(body).to include("Ảnh bill", "77.678.000")
    expect(body).not_to include("Bill con", "Bỏ qua", "Tổng bill con", "Chênh lệch", "49.981.000", "27.697.000", "12.000.000")
    # Only a link to the album page, to check its other photos and transactions.
    expect(Nokogiri::HTML(body).css(%(a[href="#{admin_bill_album_path(album)}"])).text).to include("Album ##{album.id}")
    expect(Nokogiri::HTML(body).css(".album-strip")).to be_empty
    expect(Nokogiri::HTML(body).css(".bill-viewer img").size).to eq(1)
  end

  it "shows the same on the album page" do
    get admin_bill_album_path(album)

    expect(response.body).to include("Bill con · bỏ qua", "settlement_complete").or include("Bill kết đầy đủ")
    expect(response.body).not_to include("Chênh lệch")
  end

  it "gives each of several complete bills kết its own transaction, each page showing its own photo alone" do
    several = create(:bill_album, telegram_chat: chat)
    complete = ->(amount) { document("settlement", amount).merge("lot_number" => "00#{amount / 1000}", "terminal_or_merchant_id" => "000000123456") }
    [ complete.call(5_003_000), complete.call(4_995_000) ].each do |doc|
      normalized = BillVision::Normalizer.call({ "documents" => [ doc ] }, provider: "openai", model: "gpt-test")
      create(:bill_image, bill_album: several, telegram_message: create(:telegram_message, telegram_chat: chat),
                          normalized_extraction: normalized, ocr_status: "completed")
    end
    BillAlbums::Reconciler.call(several)
    transactions = several.reload.transactions.order(:id).to_a
    expect(transactions.size).to eq(2)

    get admin_transaction_path(transactions.first)
    expect(response.body).to include("5.003.000")
    expect(response.body).not_to include("4.995.000", "Nhiều ảnh tổng kết")
    expect(response.body).to include(admin_bill_album_path(several))
    expect(Nokogiri::HTML(response.body).css(".bill-viewer img").size).to eq(1)

    get admin_bill_album_path(several)
    expect(response).to have_http_status(:ok)
    transactions.each { |transaction| expect(response.body).to include(admin_transaction_path(transaction)) }
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
