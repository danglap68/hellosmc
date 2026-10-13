require "rails_helper"

RSpec.describe "Public runner codes" do
  before { Workbook::Seed.call }

  it "shows the board without login and without the admin shell" do
    get runner_codes_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Mã chuyển tiền", "Chạm vào mã để chép.", "Theo người", "Theo HKD")
    expect(response.body).not_to include("app-sidebar", "Đăng nhập", 'href="/admin')
    doc = Nokogiri::HTML(response.body)
    codes = doc.css("#{person_board} [data-code]").map { |node| node["data-code"] }
    expect(codes).to match_array(RemitterTransfers::Codes.codes)
    expect(doc.at_css(person_board).key?("hidden")).to be(false)
    expect(doc.at_css(hkd_board).key?("hidden")).to be(true)
  end

  it "groups one person's codes together, including Chị Huệ's three TIDs" do
    get runner_codes_path

    doc = Nokogiri::HTML(response.body)
    person = doc.at_css(person_board)
    son = group_named(person, "Sơn")
    expect(son.css("[data-code]").map { |node| node["data-code"] }).to eq(%w[TK02 NM01])
    expect(son.at_css("[data-code='TK02'] .codes-card__name").text).to eq("Thiên Kim GV")
    expect(son.at_css("[data-code='TK02'] .codes-card__tid").text).to include("tid2")

    hue = group_named(person, "Chị Huệ")
    expect(hue.css("[data-code]").map { |node| node["data-code"] }).to eq(%w[ML127 ML128 ML129])
  end

  it "can open grouped by HKD, with the mã still primary" do
    get runner_codes_path(nhom: "hkd")

    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css(person_board).key?("hidden")).to be(true)
    board = doc.at_css(hkd_board)
    expect(board.key?("hidden")).to be(false)
    thien_kim = group_named(board, "Thiên Kim GV")
    expect(thien_kim.at_css(".codes-group__meta").text).to eq("001")
    expect(thien_kim.css("[data-code]").map { |node| node["data-code"] }).to eq(%w[TK01 TK02 TK03])
    expect(thien_kim.at_css("[data-code='TK01'] .codes-card__name").text).to eq("Chương")
    expect(thien_kim.at_css("[data-code='TK01'] .codes-card__code").text).to eq("TK01")
  end

  it "filters by person, HKD name, and TID" do
    get runner_codes_path, params: { q: "Sơn" }
    person = Nokogiri::HTML(response.body).at_css(person_board)
    expect(visible_codes(person)).to eq(%w[NM01 TK02])

    get runner_codes_path, params: { q: "Gat Tan" }
    person = Nokogiri::HTML(response.body).at_css(person_board)
    expect(visible_codes(person)).to eq(%w[GT01 GT02 GT03])

    get runner_codes_path, params: { q: "tid127" }
    person = Nokogiri::HTML(response.body).at_css(person_board)
    expect(visible_codes(person)).to eq(%w[ML127])
  end

  it "says when nothing matches, and omits rows the matcher would reject" do
    get runner_codes_path, params: { q: "khong co ma nay" }
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("[data-codes-board-target='empty']").key?("hidden")).to be(false)
    expect(visible_codes(doc.at_css(person_board))).to be_empty

    MerchantDealer.find_by!(transfer_code: "TK03").update!(active: false)
    dealer = create(:dealer, name: "Không Mã")
    create(:merchant_dealer, dealer: dealer, merchant: Merchant.find_by!(code: "001"), transfer_code: nil, tid_key: "tid9")

    get runner_codes_path
    expect(response.body).not_to include("TK03", "Không Mã")
    expect(RemitterTransfers::Codes.merchant_dealer_for("TK03")).to be_nil
  end

  it "follows a code edited in admin, for a signed-in user as well" do
    MerchantDealer.find_by!(transfer_code: "CF02").update!(transfer_code: "CF99")
    sign_in create(:user, :operator)

    get runner_codes_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("CF99")
    expect(response.body).not_to include("CF02")
    expect(response.body).not_to include('href="/admin')
  end

  def person_board = "[data-codes-board-target='board'][data-group='person']"
  def hkd_board = "[data-codes-board-target='board'][data-group='hkd']"

  def group_named(board, name)
    board.css("[data-code-group]").find { |node| node.at_css(".codes-group__name").text == name } ||
      raise("missing group #{name}")
  end

  def visible_codes(board)
    board.css("[data-code-card]").reject { |node| node.key?("hidden") }.map { |node| node["data-code"] }.sort
  end
end
