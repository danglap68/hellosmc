require "rails_helper"

# Smoke test: every admin page renders for an admin, in Vietnamese.
RSpec.describe "Admin pages" do
  include_context "accounting setup"

  let(:admin) { create(:user, :admin) }
  let!(:approved) { Transactions::Builder.call(bill_image: analyzed_bill).sole }
  let!(:review) { Transactions::Builder.call(bill_image: analyzed_bill(extraction: "blurry_settlement")).sole }
  let!(:merchant_alias) { create(:merchant_alias, merchant: merchant, alias: "THIEN KIM") }
  let!(:export) { create(:excel_export, generated_by: admin) }
  let!(:bill_album) { create(:bill_album, telegram_chat: chat) }

  before do
    client = instance_double(Telegram::BotClient, get_me: { "can_read_all_group_messages" => true })
    allow(Telegram::BotClient).to receive(:new).and_return(client)
    sign_in admin
  end

  it "hides the bill album and bill upload entry points from the UI" do
    get admin_root_path
    page = Nokogiri::HTML(response.body)
    expect(page.css(%(a[href="#{admin_bill_albums_path}"]))).to be_empty
    expect(page.css(%(a[href="#{new_admin_bill_upload_path}"]))).to be_empty
    expect(response.body).not_to include(new_admin_bill_upload_path)

    get admin_reviews_path
    expect(Nokogiri::HTML(response.body).css(%(a[href="#{new_admin_bill_upload_path}"]))).to be_empty
  end

  it "shows the profit KPI with its stored total, period comparison and trend" do
    get admin_root_path(period: "7d")

    page = Nokogiri::HTML(response.body)
    card = page.css(".kpi-card").find { |node| node.at_css("h2").text == "Lợi nhuận" }
    expect(card).to be_present
    expected = ApplicationController.helpers.format_vnd(Dashboard::Stats.new(period: "7d").current_snapshot[:profit])
    expect(card.at_css(".kpi-value").text).to eq(expected)
    expect(card.at_css(".delta-pill")).to be_present
    expect(card.at_css(".sparkline")).to be_present
    expect(card.text).to include("Tiền sau phí gốc trừ tiền đại lý, trên giao dịch đã duyệt")
  end

  it "defaults to today, splits total money into approved and waiting, and refreshes once a minute" do
    get admin_root_path
    page = Nokogiri::HTML(response.body)

    expect(page.at_css('.period-option[aria-current="page"]').text).to eq("Hôm nay")
    expect(page.at_css(".settlement-total h2").text).to eq("Tiền kết toán hôm nay")
    expect(page.css(".settlement-equation dt").map(&:text)).to eq([ "Đã duyệt", "Chờ xử lý / kiểm tra" ])
    expect(page.css(".settlement-status").map { |node| node["data-status"] }).to eq([ "review" ])
    expect(page.at_css(".settlement-summary").text).not_to include("Tạm giữ", "Đang xử lý", "Xử lý lỗi")
    expect(page.at_css(".settlement-summary details")["open"]).to be_nil
    expect(page.at_css(".settlement-summary details").text).to include("Đã duyệt + chờ xử lý = tổng tiền")
    expect(page.at_css('[data-controller="auto-refresh"]')["data-auto-refresh-interval-value"]).to eq("60000")
    expect(page.css(".sparkline")).to be_empty
  end

  it "keeps nonempty waiting statuses visible even when their amounts have not been read" do
    create(:transaction, status: "hold", transaction_at: Time.current, transaction_amount_vnd: 10_000)
    create(:transaction, status: "pending", transaction_at: Time.current, transaction_amount_vnd: nil)
    create(:transaction, status: "processing", transaction_at: Time.current, transaction_amount_vnd: 20_000)
    create(:transaction, status: "failed", transaction_at: Time.current, transaction_amount_vnd: nil)
    get admin_root_path
    page = Nokogiri::HTML(response.body)
    statuses = page.css(".settlement-status").index_by { |node| node["data-status"] }

    expect(statuses.keys).to eq(%w[review hold processing failed])
    expect(statuses["processing"].text).to include("2 giao dịch", "20.000 ₫")
    expect(statuses["failed"].text).to include("1 giao dịch")
    stats = Dashboard::Stats.new(period: "today")
    amounts = page.css(".settlement-equation .money").map { |node| node.text.gsub(/\D/, "").to_i }
    expect(amounts.sum).to eq(stats.current_snapshot[:gross])
  end

  it "omits the empty waiting status group when every transaction is approved" do
    review.update!(status: "rejected")
    get admin_root_path
    page = Nokogiri::HTML(response.body)

    expect(page.css(".settlement-statuses")).to be_empty
    expect(page.css(".settlement-equation dt").map(&:text)).to include("Đã duyệt", "Chờ xử lý / kiểm tra")
  end

  it "uses a merchant ranking chart with exact totals and period drill-down instead of card types" do
    [ "Cherry Coffee", "Gat Tan Day Coffe", "HKD AS CAFE", "HKD NCT MBV", "HKD tên dài để kiểm tra xuống dòng" ].each_with_index do |name, index|
      amount = (6 - index) * 1_000_000
      create(:transaction, :calculated, merchant: create(:merchant, name: name), transaction_at: Time.current,
        status: index.even? ? "approved" : "needs_review", transaction_amount_vnd: amount,
        amount_after_base_fee_vnd: amount - amount * 88 / 10_000)
    end
    get admin_root_path(period: "7d")
    page = Nokogiri::HTML(response.body)
    chart = page.at_css('[data-testid="merchant-chart"]')

    expect(chart.text).to include("Doanh số theo hộ kinh doanh", "Đã duyệt", "Chờ xử lý", merchant.name)
    expect(response.body).not_to include("Doanh số theo loại thẻ")
    amounts = chart.css(".merchant-chart-amount").map { |node| node.text.gsub(/\D/, "").to_i }
    expect(amounts.sum).to eq(Dashboard::Stats.new(period: "7d").current_snapshot[:gross])
    expect(chart.css(".merchant-chart-row").size).to eq(6)
    expect(chart.at_css(".merchant-chart-name a")["href"]).to eq(admin_transactions_path(merchant_id: merchant.id,
      date_from: Dashboard::Stats.new(period: "7d").period_start, date_to: Time.zone.today))
    expect(page.at_css("#merchant-breakdown")).to be_present
    expect(page.at_css("#merchant-breakdown").text).to include("Đã duyệt / Chờ", "Chờ")
    if ENV["SMC_DASHBOARD_PREVIEW"] == "1"
      path = Rails.root.join("tmp/diagnostics/dashboard-merchant-preview#{ENV.fetch('TEST_ENV_NUMBER', '')}.html")
      FileUtils.mkdir_p(path.dirname)
      path.write(response.body)
    end
  end

  it "labels unread merchant amounts without implying their money is zero" do
    create(:transaction, merchant: nil, status: "failed", transaction_at: nil, transaction_amount_vnd: nil)
    get admin_root_path
    chart = Nokogiri::HTML(response.body).at_css('[data-testid="merchant-chart"]')
    row = chart.css(".merchant-chart-row").find { |node| node.text.include?("Chưa gán hộ kinh doanh") }
    expect(row.at_css(".merchant-chart-amount").text).to eq("Chưa đọc được số tiền")
    expect(chart.text).to include("1 bill chưa đọc tiền", "Chưa gán hộ kinh doanh")
  end

  it "lists every page once by default and moves starred pages into Ghim" do
    get admin_root_path
    page = Nokogiri::HTML(response.body)
    expect(page.css("[data-nav-pins-target=pinned] .shell-item")).to be_empty
    expect(page.css("[data-nav-pins-target=list] .shell-item").map { _1["data-nav-pins-key"] })
      .to include("dashboard", "transactions", "reviews", "remitter_transfers")

    cookies[SettingsNavHelper::NAV_PINS_COOKIE] = "reviews,transactions,unknown"
    get admin_root_path
    page = Nokogiri::HTML(response.body)
    expect(page.css("[data-nav-pins-target=pinned] .shell-item").map { _1["data-nav-pins-key"] })
      .to eq(%w[reviews transactions])
    expect(page.css(%([data-nav-pins-target=list] [data-nav-pins-key=reviews] .shell-pin)).first["aria-pressed"]).to eq("true")
  end

  it "shows outgoing totals and the reconciliation formula with a link to all transfers in the selected period" do
    create(:remitter_transfer, status: "approved", amount_vnd: 50_000, written_at: Time.current)
    create(:remitter_transfer, status: "needs_review", amount_vnd: 20_000)
    create(:remitter_transfer, status: "processing", amount_vnd: nil)
    get admin_root_path(period: "7d")
    page = Nokogiri::HTML(response.body)
    section = page.at_css(".outgoing-summary")
    expect(section.at_css('[data-metric="outgoing-total"] .money').text).to eq("70.000 ₫")
    expect(section.at_css('[data-metric="outgoing-approved"] .money').text).to eq("50.000 ₫")
    expect(section.at_css('[data-metric="outgoing-waiting"] .money').text).to eq("20.000 ₫")
    stats = Dashboard::Stats.new(period: "7d")
    difference = ApplicationController.helpers.format_vnd(stats.current_snapshot[:dealer_payable] - 50_000)
    expect(section.at_css('[data-metric="reconciliation-difference"] .money').text).to eq(difference)
    expect(section.text).to include("1 đã ghi sheet", "1 lệnh chuyển tiền thiếu số tiền", "chưa gồm số dư kỳ trước")
    expect(section.at_css("a")["href"]).to eq(admin_remitter_transfers_path(queue: "all", date_from: stats.period_start.iso8601, date_to: stats.period_end.iso8601))
  end

  it "renders index, show, new and edit pages" do
    paths = [
      admin_root_path,
      admin_messages_path, admin_messages_path(chat_id: chat.id, q: "MB"),
      admin_message_path(approved.telegram_message),
      admin_transactions_path, admin_transactions_path(q: "000269", status: "approved", date_from: "2026-10-01"),
      admin_transaction_path(approved), admin_transaction_path(review), edit_admin_transaction_path(review),
      admin_reviews_path, admin_reviews_path(queue: "hold"), admin_review_path(review), admin_review_path(approved),
      new_admin_bill_upload_path,
      admin_dealers_path, admin_dealer_path(dealer), new_admin_dealer_path, edit_admin_dealer_path(dealer),
      admin_telegram_chats_path, admin_telegram_chats_path(filter: "inactive"), admin_telegram_chat_path(chat),
      new_admin_telegram_chat_path, edit_admin_telegram_chat_path(chat),
      admin_bill_albums_path, admin_bill_album_path(bill_album),
      admin_merchants_path, admin_merchant_path(merchant), new_admin_merchant_path, edit_admin_merchant_path(merchant),
      edit_admin_merchant_merchant_alias_path(merchant, merchant_alias),
      admin_fee_rules_path, admin_fee_rules_path(state: "current"), admin_fee_rule_path(default_rule),
      new_admin_fee_rule_path, edit_admin_fee_rule_path(default_rule),
      admin_card_types_path, new_admin_card_type_path, edit_admin_card_type_path(mb_card),
      admin_excel_exports_path, new_admin_excel_export_path, admin_excel_export_path(export),
      admin_audit_logs_path, admin_audit_logs_path(actor: "system"), admin_audit_log_path(AuditLog.first),
      admin_users_path, new_admin_user_path, edit_admin_user_path(admin),
      admin_settings_system_roles_path, admin_transfer_codes_path, new_admin_transfer_code_path,
      admin_settings_path
    ]

    paths.each do |path|
      get path
      follow_redirect! if response.redirect?
      expect(response).to have_http_status(:ok), "#{path} returned #{response.status}"
      expect(response.body).not_to include("translation missing"), "#{path} has missing translations"
      expect(response.body).not_to match(/Translation missing/i), "#{path} has missing translations"
    end
  end

  it "suggests Telegram senders on the remitter form" do
    create(:telegram_message, telegram_chat: chat, telegram_sender_id: 777, sender_name: "Lập", telegram_username: "laplap")

    get new_admin_remitter_path

    expect(response.body).to include(%(list="telegram-senders"), %(<option value="777">Lập @laplap</option>))
  end

  it "serves bill images only to signed-in users" do
    get admin_bill_image_path(approved.bill_image)
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/jpeg")

    sign_out admin
    get admin_bill_image_path(approved.bill_image)
    expect(response).to redirect_to(new_user_session_path)
  end

  it "polls a pending export with Turbo instead of a meta refresh" do
    get admin_excel_export_path(export)
    expect(response.body).to include('data-controller="auto-refresh"')
    expect(response.body).not_to include('http-equiv="refresh"')

    export.update!(status: "completed")
    get admin_excel_export_path(export)
    expect(response.body).not_to include('data-controller="auto-refresh"')
  end

  it "uses Vietnamese labels for statuses" do
    get admin_transactions_path
    expect(response.body).to include("Đã duyệt", "Cần kiểm tra")
  end
end
