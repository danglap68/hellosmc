module Telegram
  # Normalizes a raw Telegram update (Hash) into a flat, typed structure.
  # Returns nil for updates that carry no chat message (polls, joins, ...).
  class MessageParser
    MESSAGE_KEYS = %w[message channel_post].freeze
    EDIT_KEYS = %w[edited_message edited_channel_post].freeze

    SERVICE_KEYS = %w[
      new_chat_members left_chat_member new_chat_title new_chat_photo delete_chat_photo
      group_chat_created supergroup_chat_created channel_chat_created
      migrate_to_chat_id migrate_from_chat_id pinned_message
      message_auto_delete_timer_changed
    ].freeze

    Parsed = Data.define(
      :update_id, :edited, :chat_id, :chat_title, :chat_type, :message_id, :sender_id,
      :sender_name, :sender_username, :text, :sent_at, :media_group_id, :attachment, :raw_message,
      :kind, :reply_to_message_id, :forwarded_from, :edited_at
    ) do
      def image?
        attachment.present?
      end
    end

    Attachment = Data.define(:kind, :file_id, :file_unique_id, :file_size, :mime_type, :width, :height)

    def self.call(update)
      new(update).call
    end

    # Largest photo size, or an image sent as a document ("send as file").
    def self.attachment_from(message)
      message = message.to_h.deep_stringify_keys

      if message["photo"].is_a?(Array) && message["photo"].any?
        photo = message["photo"].max_by { |size| [ size["file_size"].to_i, size["width"].to_i * size["height"].to_i ] }
        return Attachment.new(
          kind: "photo", file_id: photo["file_id"], file_unique_id: photo["file_unique_id"],
          file_size: photo["file_size"], mime_type: "image/jpeg", width: photo["width"], height: photo["height"]
        )
      end

      document = message["document"]
      if document.is_a?(Hash) && document["mime_type"].to_s.start_with?("image/")
        return Attachment.new(
          kind: "document", file_id: document["file_id"], file_unique_id: document["file_unique_id"],
          file_size: document["file_size"], mime_type: document["mime_type"], width: nil, height: nil
        )
      end

      nil
    end

    def initialize(update)
      @update = update.to_h.deep_stringify_keys
    end

    def call
      key = (MESSAGE_KEYS + EDIT_KEYS).find { |candidate| @update[candidate].is_a?(Hash) }
      return nil unless key

      message = @update[key]
      chat = message["chat"]
      return nil unless chat.is_a?(Hash) && chat["id"] && message["message_id"]

      Parsed.new(
        update_id: @update["update_id"],
        edited: EDIT_KEYS.include?(key),
        chat_id: Integer(chat["id"]),
        chat_title: chat_title(chat),
        chat_type: chat["type"],
        message_id: Integer(message["message_id"]),
        sender_id: message.dig("from", "id"),
        sender_name: sender_name(message["from"]),
        sender_username: message.dig("from", "username"),
        text: (message["text"].presence || message["caption"].presence)&.strip,
        sent_at: message["date"] ? Time.zone.at(message["date"].to_i) : nil,
        media_group_id: message["media_group_id"],
        attachment: self.class.attachment_from(message),
        raw_message: message,
        kind: kind_for(message),
        reply_to_message_id: reply_to_message_id(message),
        forwarded_from: forwarded_from(message),
        edited_at: message["edit_date"] ? Time.zone.at(message["edit_date"].to_i) : nil
      )
    end

    private

    def chat_title(chat)
      chat["title"].presence ||
        [ chat["first_name"], chat["last_name"] ].compact.join(" ").presence ||
        chat["username"].presence
    end

    def sender_name(from)
      return nil unless from.is_a?(Hash)

      [ from["first_name"], from["last_name"] ].compact.join(" ").presence || from["username"]
    end

    def kind_for(message)
      return "service" if SERVICE_KEYS.any? { |key| message.key?(key) }
      return "photo" if message["photo"].is_a?(Array) && message["photo"].any?
      return "document" if message["document"].is_a?(Hash)
      return "video" if message["video"].is_a?(Hash) || message["video_note"].is_a?(Hash)
      return "voice" if message["voice"].is_a?(Hash)
      return "audio" if message["audio"].is_a?(Hash)
      return "sticker" if message["sticker"].is_a?(Hash)
      return "location" if message["location"].is_a?(Hash) || message["venue"].is_a?(Hash)
      return "contact" if message["contact"].is_a?(Hash)
      return "text" if message["text"].present? || message["caption"].present?

      "other"
    end

    def reply_to_message_id(message)
      id = message.dig("reply_to_message", "message_id")
      Integer(id) if id
    rescue ArgumentError, TypeError
      nil
    end

    def forwarded_from(message)
      origin = message["forward_origin"]
      name = if origin.is_a?(Hash)
        case origin["type"]
        when "user" then sender_name(origin["sender_user"])
        when "hidden_user" then origin["sender_user_name"]
        when "chat", "channel" then origin.dig("chat", "title") || origin.dig("sender_chat", "title")
        end
      end
      name ||= sender_name(message["forward_from"])
      name ||= message.dig("forward_from_chat", "title")
      name ||= message["forward_sender_name"]
      name.to_s.truncate(255).presence
    end
  end
end
