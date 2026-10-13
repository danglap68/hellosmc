require "rails_helper"

RSpec.describe Telegram::MessageParser do
  def message(body)
    described_class.call("update_id" => 1, "message" => body.merge("message_id" => 9, "date" => Time.current.to_i,
                                                                   "chat" => { "id" => -100, "type" => "group", "title" => "Nhóm" }))
  end

  it "classifies the kinds a group can send" do
    expect(message("text" => "xin chào").kind).to eq("text")
    expect(message("photo" => [ { "file_id" => "p" } ], "caption" => "MB").kind).to eq("photo")
    expect(message("document" => { "file_id" => "d", "mime_type" => "application/pdf" }).kind).to eq("document")
    expect(message("video" => { "file_id" => "v" }).kind).to eq("video")
    expect(message("voice" => { "file_id" => "v" }).kind).to eq("voice")
    expect(message("audio" => { "file_id" => "a" }).kind).to eq("audio")
    expect(message("sticker" => { "file_id" => "s" }).kind).to eq("sticker")
    expect(message("location" => { "latitude" => 1, "longitude" => 2 }).kind).to eq("location")
    expect(message("contact" => { "phone_number" => "090" }).kind).to eq("contact")
    expect(message("new_chat_members" => [ { "id" => 1 } ]).kind).to eq("service")
  end

  it "reads a reply and a forward" do
    parsed = message("text" => "ok", "reply_to_message" => { "message_id" => 4 },
                     "forward_origin" => { "type" => "user", "sender_user" => { "first_name" => "Lan" } })
    expect(parsed.reply_to_message_id).to eq(4)
    expect(parsed.forwarded_from).to eq("Lan")
    expect(parsed.kind).to eq("text")

    channel = message("text" => "x", "forward_origin" => { "type" => "channel", "chat" => { "title" => "Kênh" } })
    expect(channel.forwarded_from).to eq("Kênh")
  end

  it "still treats an image document as an image and a pdf as not" do
    image = message("document" => { "file_id" => "d", "mime_type" => "image/png" })
    pdf = message("document" => { "file_id" => "d", "mime_type" => "application/pdf" })
    expect(image).to be_image
    expect(pdf).not_to be_image
  end
end
