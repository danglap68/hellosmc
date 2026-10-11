class TelegramChat < ApplicationRecord
  has_many :telegram_chat_merchants, dependent: :destroy
  has_many :merchants, through: :telegram_chat_merchants
  has_many :telegram_messages, dependent: :restrict_with_error

  validates :telegram_chat_id, presence: true, uniqueness: true, numericality: { only_integer: true }
  validates :name, length: { maximum: 255 }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:name, :telegram_chat_id) }
  scope :unmapped, -> { where.missing(:telegram_chat_merchants) }

  def display_name
    name.presence || telegram_chat_id.to_s
  end

  # --- Group name template "TenDaiLy-HKD1-HKD2" -------------------------------

  def parsed_name
    Telegram::ChatNameParser.call(name)
  end

  # The agent named in the group title; nil unless exactly one active dealer
  # matches by name or code (an ambiguous or unknown title never guesses).
  def group_dealer
    token = parsed_name.agent_token
    return nil if token.blank?

    normalized = VietnameseText.normalize(token)
    matches = Dealer.active.select do |dealer|
      VietnameseText.normalize(dealer.name) == normalized || dealer.code.to_s.casecmp?(token.strip)
    end
    matches.one? ? matches.first : nil
  end

  # HKDs named in the group title that match a configured merchant exactly.
  # An HKD name may itself contain "-" ("HKD AS CAFE-CAFE MILO"), so adjacent
  # tokens are joined back, longest first, before giving up on a token.
  # A suggestion only: the admin-selected `merchants` stay the source of truth.
  def name_merchants
    tokens = parsed_name.merchant_tokens
    found = []
    index = 0
    while index < tokens.length
      length = tokens.length - index
      merchant = nil
      while length.positive? && merchant.nil?
        result = Merchants::Resolver.call(merchant_name: tokens[index, length].join("-"))
        merchant = result.merchant if result.exact?
        length -= 1 if merchant.nil?
      end
      found << merchant if merchant
      index += merchant ? length : 1
    end
    found.uniq
  end

  # Audit before/after must show HKD changes: the list lives in a join table.
  def audit_snapshot
    attributes.except("created_at", "updated_at").merge("merchant_ids" => merchant_ids.sort)
  end

  def merchant_ids_differ_from_name?
    name_merchants.any? && name_merchants.map(&:id).sort != merchant_ids.sort
  end
end
