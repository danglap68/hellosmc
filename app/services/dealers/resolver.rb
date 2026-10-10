module Dealers
  # The dealer is the agent under a resolved HKD: the TID suffix on the OCR
  # merchant name points at a merchant_dealers row. Never from the chat.
  class Resolver
    Result = Data.define(:dealer, :merchant_dealer, :source, :issue) do
      def resolved?
        dealer.present? && issue.nil?
      end
    end

    def self.call(merchant:, merchant_name:)
      new(merchant:, merchant_name:).call
    end

    def initialize(merchant:, merchant_name:)
      @merchant = merchant
      @merchant_name = merchant_name
    end

    def call
      return unresolved(nil) if @merchant.nil?

      tid_key = Workbook::TidParser.call(@merchant_name)
      return unresolved(nil) if tid_key.blank?

      link = MerchantDealer.active.find_by(merchant: @merchant, tid_key: tid_key)
      return unresolved(nil) unless link

      dealer = link.dealer
      return Result.new(dealer:, merchant_dealer: link, source: "tid", issue: "dealer_inactive") unless dealer.active?

      Result.new(dealer:, merchant_dealer: link, source: "tid", issue: nil)
    end

    private

    def unresolved(merchant_dealer)
      Result.new(dealer: nil, merchant_dealer: merchant_dealer, source: nil, issue: "dealer_unmapped")
    end
  end
end
