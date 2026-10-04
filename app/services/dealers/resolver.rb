module Dealers
  # Dealer comes from configuration, never from OCR:
  # Telegram chat -> telegram_chats.dealer, or the dealer chosen on manual upload.
  class Resolver
    Result = Data.define(:dealer, :source, :issue) do
      def resolved?
        dealer.present? && issue.nil?
      end
    end

    def self.call(bill_image:)
      new(bill_image).call
    end

    def initialize(bill_image)
      @bill_image = bill_image
    end

    def call
      dealer, source =
        if @bill_image.manual_upload?
          [ Dealer.find_by(id: @bill_image.manual_dealer_id), "manual_upload" ]
        else
          [ @bill_image.telegram_chat&.dealer, "telegram_chat" ]
        end

      return Result.new(dealer: nil, source: source, issue: "dealer_unmapped") if dealer.nil?
      return Result.new(dealer: dealer, source: source, issue: "dealer_inactive") unless dealer.active?

      Result.new(dealer: dealer, source: source, issue: nil)
    end
  end
end
