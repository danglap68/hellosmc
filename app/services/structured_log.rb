# One JSON line per business event, always carrying the relevant identifiers
# (telegram_chat_id, telegram_message_id, bill_image_id, transaction_id, job_id).
# Never pass secrets in fields.
module StructuredLog
  module_function

  def info(event, **fields)
    Rails.logger.info(payload(event, fields))
  end

  def warn(event, **fields)
    Rails.logger.warn(payload(event, fields))
  end

  def error(event, **fields)
    Rails.logger.error(payload(event, fields))
  end

  def payload(event, fields)
    { event: event, at: Time.current.utc.iso8601(3) }.merge(fields).compact.to_json
  end
end
