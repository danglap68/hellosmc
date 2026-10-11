require "rails_helper"

RSpec.describe "Merchants admin" do
  before { sign_in create(:user, :admin) }

  it "adds a TID agent via the nested form" do
    merchant = create(:merchant, name: "001_ HỘ KINH DOANH THIÊN KIM GV", code: "001")
    chuong = create(:dealer, name: "Chương")

    patch admin_merchant_path(merchant), params: {
      merchant: { name: merchant.name, code: merchant.code,
                  merchant_dealers_attributes: { "0" => { dealer_id: chuong.id, tid_key: "tid1",
                                                          ds_header: "Chương (tid1)", rd_agent_label: "Chương" } } }
    }

    expect(response).to redirect_to(admin_merchant_path(merchant))
    link = merchant.merchant_dealers.find_by!(tid_key: "tid1")
    expect(link.dealer).to eq(chuong)
    expect(link.ds_header).to eq("Chương (tid1)")
    expect(link.tid_label).to eq("tid1")
    expect(link.ds_sheet_anchor).to eq(merchant.name)
  end

  it "removes a TID agent via _destroy" do
    merchant = create(:merchant, name: "001_ HỘ KINH DOANH THIÊN KIM GV", code: "001")
    chuong = create(:dealer, name: "Chương")
    link = create(:merchant_dealer, merchant: merchant, dealer: chuong, tid_key: "tid1",
                  ds_sheet_anchor: "Thiên Kim GV", ds_header: "Chương (tid1)", rd_agent_label: "Chương")

    patch admin_merchant_path(merchant), params: {
      merchant: { name: merchant.name, code: merchant.code,
                  merchant_dealers_attributes: { "0" => { id: link.id, _destroy: "1" } } }
    }

    expect(response).to redirect_to(admin_merchant_path(merchant))
    expect(merchant.merchant_dealers.count).to eq(0)
  end
end
