require "rails_helper"

# The review page of an album total shows every photo of the album (bill con +
# tổng kết) so the reviewer can check the total against the child bills.
RSpec.describe "Album photos on the review page" do
  include_context "accounting setup"

  let(:album) { create(:bill_album, telegram_chat: chat, status: "needs_review", child_count: 1,
                                    child_total_vnd: 11_445_000, transfer_amount_vnd: 11_445_000, match_difference_vnd: 0) }
  let!(:total_image) do
    analyzed_bill.tap { |image| image.update!(bill_album: album) }
  end
  let!(:child_image) do
    analyzed_bill(extraction: "child_receipt").tap { |image| image.update!(bill_album: album) }
  end
  let!(:transaction) { Transactions::Builder.call(bill_image: total_image).sole }

  before { sign_in create(:user, :admin) }

  it "lists every album photo with its role and the reconciliation totals" do
    get admin_review_path(transaction)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(admin_bill_image_path(total_image), admin_bill_image_path(child_image))
    expect(response.body).to include("Album ##{album.id} · 2 ảnh", "Tổng kết", "Bill con")
    expect(response.body).to include(%(data-image-viewer-src-param="#{admin_bill_image_path(child_image)}"))
  end

  it "shows no album strip for a single photo" do
    single = Transactions::Builder.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole

    get admin_review_path(single)

    expect(response.body).not_to include("album-strip")
  end
end
