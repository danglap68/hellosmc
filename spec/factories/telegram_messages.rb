FactoryBot.define do
  factory :telegram_message do
    telegram_chat
    sequence(:telegram_message_id) { |n| 1000 + n }
    sequence(:telegram_update_id) { |n| 500_000 + n }
    telegram_sender_id { 42 }
    sender_name { "Nhân viên" }
    message_text { nil }
    sent_at { Time.current }
    processing_status { "queued" }
    raw_payload do
      {
        "update_id" => telegram_update_id,
        "message" => {
          "message_id" => telegram_message_id,
          "chat" => { "id" => telegram_chat.telegram_chat_id, "type" => "supergroup", "title" => telegram_chat.name },
          "date" => sent_at.to_i,
          "caption" => message_text,
          "photo" => [ { "file_id" => "file-#{telegram_message_id}", "file_unique_id" => "uniq-#{telegram_message_id}",
                         "file_size" => 1000, "width" => 800, "height" => 1200 } ]
        }.compact
      }
    end
  end
end
