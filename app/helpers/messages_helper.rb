module MessagesHelper
  TONES = 6

  def chat_tone(message)
    key = message.telegram_sender_id.presence || message.sender_name.presence || message.id
    Zlib.crc32(key.to_s) % TONES
  end

  def chat_initial(message)
    message.sender_name.to_s.strip.first&.upcase || "?"
  end

  def chat_time(time)
    return "—" if time.blank?
    return time.strftime("%H:%M") if time.to_date == Time.zone.today

    l(time, format: :short)
  end

  def chat_preview(message)
    return t("messages.index.no_preview") unless message

    who = message.sender_name.presence
    body = message.display_body
    who ? "#{who}: #{body}" : body
  end
end
