module CardTypes
  # Priority: explicit Telegram tag -> merchant default -> dealer default -> system default ("normal").
  # Conflicting explicit tags are never resolved silently.
  class Resolver
    Result = Data.define(:card_type, :source, :detected_keys, :issue) do
      def resolved?
        card_type.present? && issue.nil?
      end
    end

    def self.call(message_text: nil, explicit_key: nil, merchant: nil, dealer: nil)
      new(message_text: message_text, explicit_key: explicit_key, merchant: merchant, dealer: dealer).call
    end

    def initialize(message_text:, explicit_key:, merchant:, dealer:)
      @message_text = message_text
      @explicit_key = explicit_key
      @merchant = merchant
      @dealer = dealer
    end

    def call
      if @explicit_key.present?
        card_type = CardType.active.find_by(key: @explicit_key)
        return result(card_type, "manual_upload", [ @explicit_key ], card_type ? nil : "card_type_unknown")
      end

      keys = Telegram::CardTypeParser.call(@message_text)
      return result(nil, "message_tag", keys, "card_type_conflict") if keys.size > 1
      return result(CardType.find_by(key: keys.first), "message_tag", keys, nil) if keys.one?

      if (card_type = active_default(@merchant))
        return result(card_type, "merchant_default", keys, nil)
      end
      if (card_type = active_default(@dealer))
        return result(card_type, "dealer_default", keys, nil)
      end

      card_type = CardType.active.find_by(key: CardType::DEFAULT_KEY)
      result(card_type, "system_default", keys, card_type ? nil : "card_type_unknown")
    end

    private

    def active_default(owner)
      card_type = owner&.default_card_type
      card_type if card_type&.active?
    end

    def result(card_type, source, keys, issue)
      Result.new(card_type: card_type, source: source, detected_keys: keys, issue: issue)
    end
  end
end
