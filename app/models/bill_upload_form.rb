require "digest"

# Form object for a manual bill upload. MIME type is detected from the file
# content, not trusted from the browser.
class BillUploadForm
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :dealer_id, :integer
  attribute :card_type_key, :string
  attribute :note, :string
  attr_accessor :image, :user

  validates :image, :dealer_id, presence: true
  validate :dealer_exists
  validate :card_type_exists
  validate :image_valid

  def save
    return nil unless valid?

    bytes = image_bytes
    sha256 = Digest::SHA256.hexdigest(bytes)
    width, height = FastImage.size(StringIO.new(bytes))
    original = BillImage.analyzable.find_by(sha256: sha256)
    if original
      errors.add(:image, :already_uploaded, id: original.id)
      return nil
    end

    bill_image = BillImage.new(
      source: "manual_upload", uploaded_by: user, sha256: sha256, mime_type: detected_mime_type,
      file_size: bytes.bytesize, width: width, height: height, ocr_status: "pending",
      metadata: { "dealer_id" => dealer_id, "card_type_key" => card_type_key.presence, "note" => note.presence }.compact
    )
    bill_image.image.attach(io: StringIO.new(bytes), filename: "upload-#{Time.current.to_i}.#{extension}",
                            content_type: detected_mime_type, identify: false,
                            key: "bills/#{Time.current.strftime('%Y/%m/%d')}/#{SecureRandom.uuid}.#{extension}")
    bill_image.save!
    AuditLogger.log!(actor: user, action: "bill_image.uploaded", auditable: bill_image,
                     after_data: { "dealer_id" => dealer_id, "card_type_key" => card_type_key.presence, "sha256" => sha256 })
    bill_image
  end

  private

  def image_bytes
    @image_bytes ||= begin
      image.rewind
      image.read.b
    end
  end

  def detected_mime_type
    @detected_mime_type ||= Marcel::MimeType.for(StringIO.new(image_bytes))
  end

  def extension
    { "image/jpeg" => "jpg", "image/png" => "png", "image/webp" => "webp" }.fetch(detected_mime_type, "bin")
  end

  def dealer_exists
    errors.add(:dealer_id, :invalid) if dealer_id.present? && !Dealer.active.exists?(dealer_id)
  end

  def card_type_exists
    return if card_type_key.blank?

    errors.add(:card_type_key, :invalid) unless CardType.active.exists?(key: card_type_key)
  end

  def image_valid
    return if image.blank?
    return errors.add(:image, :invalid) unless image.respond_to?(:read)

    errors.add(:image, :too_large) if image.size > AppConfig.max_bill_image_bytes
    errors.add(:image, :invalid_content_type) unless detected_mime_type.in?(BillImage::ALLOWED_MIME_TYPES)
  end
end
