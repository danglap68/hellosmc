module Telegram
  # Detects explicit card type tags ("MB", "Napas", ...) in a Telegram message.
  # Matching is whole-word on diacritic-free, lower-cased text, so "MB" matches
  # "mb", "#MB" and "MB." but not "member". Returns every distinct key found;
  # more than one key means the message is ambiguous.
  class CardTypeParser
    def self.call(text, card_types: nil)
      new(text, card_types: card_types).call
    end

    def initialize(text, card_types: nil)
      @text = text
      @card_types = card_types
    end

    def call
      normalized = VietnameseText.normalize(@text)
      return [] if normalized.blank?

      padded = " #{normalized} "
      card_types.select { |card_type| card_type.match_tokens.any? { |token| padded.include?(" #{token} ") } }
                .map(&:key)
                .uniq
    end

    private

    def card_types
      @card_types ||= CardType.active.ordered.to_a
    end
  end
end
