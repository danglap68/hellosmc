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

  it "lists groups and asks which conversation to open" do
    text_message(chat, sender: "Lan", text: "xin chào", sent_at: Time.current)

    get admin_messages_path

    expect(response).to have_http_status(:ok)
    list = Nokogiri::HTML(response.body).at_css(".chat-conv-list").text
    expect(list).to include(chat.display_name, "Telegram", "Lan: xin chào")
    expect(response.body).to include("Chọn một nhóm để xem lịch sử nói chuyện.")
    expect(response.body).not_to include("chat-log")
    expect(response.body).not_to include("card-table")
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
    expect(response.body).not_to include("khong-hien")

    sign_in create(:user, :operator)
    get admin_message_path(message)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("MB", admin_transaction_path(message.transactions.sole), admin_remitter_transfer_path(message.remitter_transfer))
    expect(response.body).not_to include("JSON thô", "khong-hien")

    sign_in create(:user, :admin)
    get admin_message_path(message)
    expect(response.body).to include("JSON thô", "khong-hien")

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
end
