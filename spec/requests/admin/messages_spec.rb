require "rails_helper"

RSpec.describe "Admin messages" do
  include_context "accounting setup"

  let(:client) { instance_double(Telegram::BotClient, get_me: { "can_read_all_group_messages" => true }) }

  before do
    allow(Telegram::BotClient).to receive(:new).and_return(client)
    sign_in create(:user, :admin)
  end

  def text_message(chat, sender:, text:, **attrs)
    create(:telegram_message, {
      telegram_chat: chat, sender_name: sender, message_text: text, kind: "text", processing_status: "ignored",
      raw_payload: { "message" => { "text" => text } }
    }.merge(attrs))
  end

  it "lists groups and opens the latest conversation on desktop without a blank stage" do
    text_message(chat, sender: "Lan", text: "xin chào", sent_at: Time.current)

    get admin_messages_path

    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    list = page.at_css(".chat-inbox").text
    expect(list).to include(chat.display_name, "Telegram", "Lan: xin chào")
    expect(page.at_css(".chat-log").text).to include("xin chào")
    expect(page.at_css(".chat-conv[aria-current=page]")["href"]).to eq(admin_messages_path(chat_id: chat.id))
    expect(page.at_css(".chat-app")["class"]).not_to include("chat-app-thread")
    expect(response.body).not_to include("card-table")
  end

  it "keeps ordinary group silence out of the reading flow and puts collection details behind the info button" do
    create(:telegram_chat, name: "Nhóm ít hoạt động", active: true)
    text_message(chat, sender: "Lan", text: "tin mới", sent_at: Time.current)
    get admin_messages_path
    page = Nokogiri::HTML(response.body)

    expect(response.body).not_to include("Nhóm đang bật nhưng không có tin trong 24 giờ:")
    expect(page.css(".chat-note")).to be_empty
    expect(page.at_css("#chat-info")["hidden"]).not_to be_nil
    expect(page.at_css(".chat-collection")["open"]).to be_nil
    expect(page.at_css(".chat-info-toggle")["aria-controls"]).to eq("chat-info")
  end

  it "filters groups by an unaccented name and bill processing state" do
    named = create(:telegram_chat, name: "Anh Lập MB14", active: false)
    create(:telegram_chat, name: "Anh Thọ MB15", active: true)
    get admin_messages_path(group_q: "lap", filter: "inactive")
    page = Nokogiri::HTML(response.body)

    expect(page.css(".chat-conv-name").map(&:text)).to eq([ named.name ])
    expect(page.at_css(".chat-stage-head").text).to include(named.name)
    expect(page.at_css(".chat-conv")["href"]).to eq(admin_messages_path(group_q: "lap", filter: "inactive", chat_id: named.id))
    get admin_messages_path(group_q: "không có nhóm")
    expect(Nokogiri::HTML(response.body).at_css(".chat-inbox").text).to include("Không tìm thấy nhóm", "Xóa bộ lọc")
  end

  it "searches text and senders only in the selected group and treats SQL wildcards literally" do
    text_message(chat, sender: "Lan", text: "Phí 1% cho bill MB14", sent_at: 2.minutes.ago)
    text_message(chat, sender: "Minh", text: "Phí 100 đồng", sent_at: 1.minute.ago)
    other = create(:telegram_chat)
    text_message(other, sender: "Lan", text: "Ngoài nhóm 1%", sent_at: Time.current)
    get admin_messages_path(chat_id: chat.id, q: "%")
    page = Nokogiri::HTML(response.body)

    expect(page.at_css(".chat-log").text).to include("Phí 1%")
    expect(page.at_css(".chat-log").text).not_to include("100 đồng", "Ngoài nhóm")
    expect(page.at_css(".chat-window-note").text).to include("1 tin nhắn khớp tìm kiếm")
    get admin_messages_path(chat_id: chat.id, q: "minh")
    expect(Nokogiri::HTML(response.body).at_css(".chat-log").text).to include("100 đồng")
    get admin_messages_path(chat_id: chat.id, q: "không có")
    expect(Nokogiri::HTML(response.body).at_css(".chat-log").text).to include("Không có tin nhắn phù hợp")
  end

  it "escapes HTML in messages and search highlights" do
    text_message(chat, sender: "Lan", text: '<script>alert("x")</script> & MB14', sent_at: Time.current)
    get admin_messages_path(chat_id: chat.id, q: "script")
    body = Nokogiri::HTML(response.body).at_css(".chat-text")

    expect(body.css("script")).to be_empty
    expect(body.text).to eq('<script>alert("x")</script> & MB14')
    expect(body.css("mark").map(&:text)).to eq(%w[script script])
  end

  it "paginates tied timestamps without duplicates and allows returning to the latest window" do
    82.times { |index| text_message(chat, sender: "Lan", text: "tin #{index}", sent_at: Time.current) }
    get admin_messages_path(chat_id: chat.id)
    page = Nokogiri::HTML(response.body)
    newest_ids = page.css(".chat-entry").map { |node| node["id"] }
    expect(newest_ids.size).to eq(80)
    get page.at_css(".chat-older a")["href"]
    older = Nokogiri::HTML(response.body)
    older_ids = older.css(".chat-entry").map { |node| node["id"] }

    expect(older_ids.size).to eq(2)
    expect(older_ids & newest_ids).to be_empty
    expect(older.at_css(".chat-window-note").text).to include("Đang xem lịch sử cũ", "Về tin mới nhất")
    expect(older.at_css(".chat-thread")["data-chat-thread-history-value"]).to eq("true")
  end

  it "opens one group as a thread, oldest first, and leaves the other group out of it" do
    other = create(:telegram_chat, name: "Nhóm khác")
    text_message(chat, sender: "Lan", text: "tin cũ", sent_at: 2.hours.ago, telegram_sender_id: 2)
    text_message(chat, sender: "Minh", text: "tin mới", sent_at: 1.hour.ago, telegram_sender_id: 4, reply_to_message_id: 4, forwarded_from: "Kênh")
    text_message(other, sender: "Hùng", text: "bên kia", sent_at: Time.current)
    create(:telegram_message, telegram_chat: chat, sender_name: "Lan", message_text: nil, kind: "voice",
                              sent_at: 30.minutes.ago, processing_status: "queued",
                              raw_payload: { "message" => { "voice" => { "file_id" => "v" } } })

    get admin_messages_path(chat_id: chat.id)

    page = Nokogiri::HTML(response.body)
    expect(page.at_css(".chat-stage-head").text).to include(chat.display_name, "Telegram")
    log = page.at_css(".chat-log")
    expect(log.text).to include("Lan", "Minh", "tin cũ", "tin mới", "[Voice]", "Trả lời tin 4", "Chuyển tiếp từ Kênh")
    expect(log.text.index("tin cũ")).to be < log.text.index("tin mới")
    expect(log.text.index("tin mới")).to be < log.text.index("[Voice]")
    expect(log.text).not_to include("bên kia")
    lan = log.css(".chat-bubble").select { |node| node.at_css(".chat-sender").text == "Lan" }
    minh = log.css(".chat-bubble").find { |node| node.at_css(".chat-sender").text == "Minh" }
    expect(lan.map { |node| node["class"] }.uniq.size).to eq(1)
    expect(lan.first["class"]).not_to eq(minh["class"])
    expect(page.at_css(".chat-conv-list").text).to include("Nhóm khác", "Hùng: bên kia")
  end

  it "gives different names different colors even when the sender id is the same" do
    text_message(chat, sender: "Hoàng Chương", text: "bên chương", telegram_sender_id: 99, sent_at: 2.minutes.ago)
    text_message(chat, sender: "Anh tên là Lập", text: "bên lập", telegram_sender_id: 99, sent_at: 1.minute.ago)
    text_message(chat, sender: "Anh tên là Lập", text: "lập nói tiếp", telegram_sender_id: 99, sent_at: Time.current)

    get admin_messages_path(chat_id: chat.id)

    bubbles = Nokogiri::HTML(response.body).css(".chat-log .chat-bubble")
    chuong = bubbles.find { |node| node.at_css(".chat-sender").text == "Hoàng Chương" }
    lap = bubbles.select { |node| node.at_css(".chat-sender").text == "Anh tên là Lập" }
    expect(lap.map { |node| node["class"] }.uniq.size).to eq(1)
    expect(chuong["class"]).not_to eq(lap.first["class"])
    expect(chuong["class"]).to match(/chat-tone-\d+/)
  end

  it "renders a downloaded photo in the bubble and leaves an undownloaded one as a label" do
    photo = create(:telegram_message, telegram_chat: chat, sender_name: "Lan", message_text: nil, kind: "photo",
                                      processing_status: "processed", sent_at: 2.minutes.ago)
    image = create(:bill_image, telegram_message: photo)
    create(:telegram_message, telegram_chat: chat, sender_name: "Minh", message_text: nil, kind: "photo",
                              processing_status: "ignored", sent_at: 1.minute.ago,
                              raw_payload: { "message" => { "photo" => [ { "file_id" => "not-downloaded" } ] } })

    get admin_messages_path(chat_id: chat.id)

    bubbles = Nokogiri::HTML(response.body).css(".chat-log .chat-bubble")
    downloaded = bubbles.find { |node| node.at_css(".chat-sender").text == "Lan" }
    missing = bubbles.find { |node| node.at_css(".chat-sender").text == "Minh" }
    expect(downloaded.at_css("img.chat-photo")["src"]).to eq(admin_bill_image_path(image))
    expect(downloaded.at_css("a[target=_blank]")).to be_nil
    expect(downloaded.at_css("button.chat-photo-link")["data-chat-preview-src-param"]).to eq(admin_bill_image_path(image))
    expect(downloaded.text).not_to include("[Ảnh]")
    expect(missing.at_css("img")).to be_nil
    expect(missing.text).to include("[Ảnh]")
  end

  it "links a photo's detail to the transaction and the transfer, and hides raw JSON from an operator" do
    message = create(:telegram_message, telegram_chat: chat, sender_name: "Lan", message_text: "MB", kind: "photo",
                                        processing_status: "processed", raw_payload: { "secret_field" => "khong-hien" })
    create(:transaction, telegram_message: message, dealer: dealer, merchant: merchant, card_type: normal_card)
    create(:remitter_transfer, telegram_message: message)

    get admin_messages_path(chat_id: chat.id)
    expect(response.body).to include(admin_message_path(message))
    expect(Nokogiri::HTML(response.body).at_css(".chat-message-results").text).to include("Giao dịch #", "Chuyển tiền #")
    expect(response.body).not_to include("khong-hien")

    sign_in create(:user, :operator)
    get admin_message_path(message)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("MB", admin_transaction_path(message.transactions.sole), admin_remitter_transfer_path(message.remitter_transfer))
    expect(response.body).not_to include("Dữ liệu kỹ thuật", "khong-hien")

    sign_in create(:user, :admin)
    get admin_message_path(message)
    expect(response.body).to include("Dữ liệu kỹ thuật", "khong-hien")
    expect(Nokogiri::HTML(response.body).at_css("details.technical-details")["open"]).to be_nil

    sign_in create(:user, :viewer)
    get admin_messages_path
    expect(response).to have_http_status(:forbidden)
  end

  it "does not select raw_payload for the conversation list or the thread" do
    text_message(chat, sender: "Lan", text: "xin chào", sent_at: Time.current)
    queries = []
    ActiveSupport::Notifications.subscribed(->(*, payload) { queries << payload[:sql] }, "sql.active_record") do
      get admin_messages_path
      get admin_messages_path(chat_id: chat.id)
    end

    listed = queries.grep(/message_text/)
    expect(listed).not_to be_empty
    expect(listed.join).not_to include("raw_payload")
  end

  it "shows the message ids that look missing as a note on that conversation" do
    [ 1, 2, 5 ].each do |id|
      text_message(chat, sender: "Lan", text: "tin #{id}", telegram_message_id: id, sent_at: Time.current)
    end

    get admin_messages_path(chat_id: chat.id, gaps: 1)
    expect(response.body).to include("3, 4")
    expect(Nokogiri::HTML(response.body).at_css(".chat-log").text).to include("tin 1", "Lan")
  end

  it "renders dated evidence and reply context with long group names" do
    chat.update!(name: "Anh Thọ MB15 · Hội thoại kiểm thử")
    [ "Cherry Coffee", "Anh Nghĩa MB14 SP135", "Anh Trân MB14", "Cường Duyên SP135 MB14 QR11", "Anh Lập MB14" ].each_with_index do |name, index|
      group = create(:telegram_chat, name: name, active: index.even?)
      text_message(group, sender: "Anh tên là Lập", text: "Đã gửi bill kết toán hôm nay", sent_at: (index + 1).hours.ago)
    end
    prior = text_message(chat, sender: "Anh tên là Lập", text: "Em gửi bill kết toán ca chiều nhé anh.", sent_at: 1.day.ago)
    photo = create(:telegram_message, telegram_chat: chat, sender_name: "Nguyễn Kim", message_text: "Bill MB15 đã kết toán.", kind: "photo", processing_status: "processed", sent_at: 4.minutes.ago)
    image = create(:bill_image, telegram_message: photo)
    create(:transaction, :approved, telegram_message: photo, bill_image: image, merchant: merchant, dealer: dealer, card_type: normal_card, transaction_amount_vnd: 11_445_000)
    text_message(chat, sender: "Anh tên là Lập", text: "Đã nhận bill. Anh kiểm tra giúp em giao dịch này nhé.", reply_to_message_id: prior.telegram_message_id, sent_at: 2.minutes.ago)
    get admin_messages_path(chat_id: chat.id)
    page = Nokogiri::HTML(response.body)

    expect(page.css(".chat-date").map(&:text)).to eq([ "Hôm qua", "Hôm nay" ])
    expect(page.at_css(".chat-reply").text).to include(prior.message_text)
    expect(page.at_css(".chat-message-results").text).to include("11.445.000 ₫", "Đã duyệt")
    if ENV["SMC_CHAT_PREVIEW"] == "1"
      path = Rails.root.join("tmp/diagnostics/chat-preview#{ENV.fetch('TEST_ENV_NUMBER', '')}.json")
      FileUtils.mkdir_p(path.dirname)
      payload = { thread: response.body, images: { admin_bill_image_path(image) => Base64.strict_encode64(image.image.download) } }
      get admin_messages_path
      payload[:inbox] = response.body
      path.write(JSON.generate(payload))
    end
  end
end
