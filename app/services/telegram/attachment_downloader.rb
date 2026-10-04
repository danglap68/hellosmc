require "digest"

module Telegram
  # Downloads the image of a stored Telegram message, fingerprints it and
  # stores it (R2 in production) as a BillImage. Idempotent:
  #
  # * the same message never produces two BillImages;
  # * the same Telegram file (file_unique_id) is recorded as a duplicate;
  # * identical bytes (SHA256) are recorded as a duplicate and not re-analyzed.
  class AttachmentDownloader
    class InvalidImageError < StandardError; end

    def self.call(telegram_message, client: nil)
      new(telegram_message, client: client).call
    end

    def initialize(telegram_message, client: nil)
      @message = telegram_message
      @client = client
    end

    def call
      existing = @message.bill_images.first
      return existing if existing

      attachment = MessageParser.attachment_from(@message.raw_message)
      return nil unless attachment

      if (original = BillImage.find_by(telegram_file_unique_id: attachment.file_unique_id))
        return record_duplicate(attachment, original, reason: "telegram_file_unique_id")
      end

      bytes = download(attachment)
      sha256 = Digest::SHA256.hexdigest(bytes)
      mime_type = detect_mime_type(bytes)
      width, height = FastImage.size(StringIO.new(bytes)) || [ attachment.width, attachment.height ]

      if (original = BillImage.analyzable.where(sha256: sha256).order(:id).first)
        return record_duplicate(attachment, original, reason: "sha256", sha256: sha256, mime_type: mime_type,
                                                      file_size: bytes.bytesize, width: width, height: height)
      end

      bill_image = BillImage.new(
        telegram_message: @message,
        source: "telegram",
        telegram_file_id: attachment.file_id,
        telegram_file_unique_id: attachment.file_unique_id,
        sha256: sha256,
        mime_type: mime_type,
        file_size: bytes.bytesize,
        width: width,
        height: height,
        ocr_status: "pending"
      )
      bill_image.image.attach(
        io: StringIO.new(bytes),
        filename: "telegram-#{@message.telegram_chat.telegram_chat_id}-#{@message.telegram_message_id}.#{extension_for(mime_type)}",
        content_type: mime_type,
        key: storage_key(mime_type),
        identify: false
      )
      bill_image.save!

      StructuredLog.info("telegram.attachment_stored", telegram_chat_id: @message.telegram_chat.telegram_chat_id,
                                                       telegram_message_id: @message.telegram_message_id,
                                                       bill_image_id: bill_image.id, sha256: sha256, file_size: bytes.bytesize)
      bill_image
    rescue ActiveRecord::RecordNotUnique
      existing = @message.bill_images.reload.first
      return existing if existing

      original = BillImage.find_by(telegram_file_unique_id: attachment.file_unique_id)
      raise unless original

      record_duplicate(attachment, original, reason: "telegram_file_unique_id")
    end

    private

    def client
      @client ||= BotClient.new
    end

    def download(attachment)
      max_bytes = AppConfig.max_bill_image_bytes
      if attachment.file_size.to_i > max_bytes
        raise BotClient::FileTooLargeError, "Telegram file exceeds #{max_bytes} bytes"
      end

      file = client.get_file(attachment.file_id)
      client.download_file(file.fetch("file_path"), max_bytes: max_bytes)
    end

    def detect_mime_type(bytes)
      mime_type = Marcel::MimeType.for(StringIO.new(bytes))
      return mime_type if mime_type.in?(BillImage::ALLOWED_MIME_TYPES)

      raise InvalidImageError, "Unsupported image type: #{mime_type}"
    end

    def record_duplicate(attachment, original, reason:, **attributes)
      bill_image = BillImage.create!(
        telegram_message: @message,
        source: "telegram",
        telegram_file_id: attachment.file_id,
        duplicate_of: original,
        ocr_status: "duplicate",
        metadata: { "duplicate_reason" => reason, "telegram_file_unique_id" => attachment.file_unique_id },
        **attributes
      )
      StructuredLog.warn("telegram.attachment_duplicate", telegram_chat_id: @message.telegram_chat.telegram_chat_id,
                                                          telegram_message_id: @message.telegram_message_id,
                                                          bill_image_id: bill_image.id, duplicate_of_id: original.id,
                                                          reason: reason)
      bill_image
    end

    def storage_key(mime_type)
      "bills/#{Time.current.strftime('%Y/%m/%d')}/#{SecureRandom.uuid}.#{extension_for(mime_type)}"
    end

    def extension_for(mime_type)
      { "image/jpeg" => "jpg", "image/png" => "png", "image/webp" => "webp" }.fetch(mime_type, "bin")
    end
  end
end
