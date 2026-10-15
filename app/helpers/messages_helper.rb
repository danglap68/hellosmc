module MessagesHelper
  TONES = 12

  # Name first, so two people never share a color just because their ids
  # land in the same bucket. Username, then sender id, if the name is blank.
  def chat_sender_key(message = nil, name: nil, username: nil, sender_id: nil, id: nil)
    if message
      name = message.sender_name
      username = message.telegram_username
      sender_id = message.telegram_sender_id
      id = message.id
    end
    name.to_s.strip.presence ||
      username.to_s.delete_prefix("@").strip.presence ||
      sender_id.presence&.to_s ||
      "message-#{id}"
  end

  # Preferred slot is a stable hash of the name. If two names want the same
  # slot, the later one (sorted) takes the next free color, so a group does
  # not paint different people the same until every tone is used.
  def chat_tone_map(keys)
    taken = {}
    keys.map { |key| key.to_s }.uniq.sort.each_with_object({}) do |key, map|
      preferred = Zlib.crc32(key) % TONES
      tone = TONES.times.lazy.map { |step| (preferred + step) % TONES }.find { |candidate| !taken.key?(candidate) }
      tone ||= preferred
      taken[tone] = key
      map[key] = tone
    end
  end

  def chat_tone(message, tones = nil)
    key = chat_sender_key(message)
    return tones[key] if tones&.key?(key)

    Zlib.crc32(key) % TONES
  end

  def chat_initial(message)
    message.sender_name.to_s.strip.first&.upcase || "?"
  end

  def chat_time(time)
    return "—" if time.blank?
    return time.strftime("%H:%M") if time.to_date == Time.zone.today

    l(time, format: :short)
  end

  # A downloaded bill image. Photos that were only stored, never fetched, stay a label.
  def chat_photo(message)
    message.bill_images.detect { |image| image.image.attached? || image.duplicate_of&.image&.attached? }
  end

  def chat_preview(message)
    return t("messages.index.no_preview") unless message

    who = message.sender_name.presence
    body = message.display_body
    who ? "#{who}: #{body}" : body
  end

  def chat_navigation(**overrides)
    { group_q: @group_query.presence, filter: (@filter unless @filter == "all") }.merge(overrides).compact
  end

  def chat_date(time)
    return t("messages.index.unknown_date") if time.blank?
    return t("messages.index.today") if time.to_date == Time.zone.today
    return t("messages.index.yesterday") if time.to_date == Time.zone.yesterday

    l(time.to_date, format: :long)
  end

  def chat_list_time(time)
    return "" if time.blank?
    return time.strftime("%H:%M") if time.to_date == Time.zone.today
    return t("messages.index.yesterday") if time.to_date == Time.zone.yesterday

    time.strftime(time.year == Time.zone.today.year ? "%d/%m" : "%d/%m/%y")
  end

  def chat_highlight(text)
    @query.present? ? highlight(h(text), @query, sanitize: false) : text
  end
end
