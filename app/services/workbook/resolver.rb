module Workbook
  # Picks the HKD, DS-MB agent (via TID) and remitter for a Hello SMC write.
  # The agent re-resolves by TID (not just transaction.dealer) because a dealer
  # like Chị Huệ owns several TIDs under one HKD; only tid_key picks the right row.
  class Resolver
    Result = Data.define(:status, :merchant, :merchant_dealer, :remitter, :issue) do
      def identified?
        status == :identified
      end

      def unidentified?
        status == :unidentified
      end
    end

    def self.call(transaction:)
      new(transaction).call
    end

    def initialize(transaction)
      @transaction = transaction
    end

    def call
      merchant = @transaction.merchant || @transaction.bill_image&.telegram_chat&.merchant
      return unidentified("merchant_missing", merchant) unless merchant

      # Agent TID comes only from the OCR merchant name; terminal_or_merchant_id
      # is a merchant identifier (MID) and does not tell which agent to use.
      tid_key = TidParser.call(ocr_merchant_name)
      return unidentified("agent_tid_missing", merchant) if tid_key.blank?

      link = MerchantDealer.active.find_by(merchant:, tid_key:)
      return unidentified("agent_tid_unmapped", merchant) unless link

      remitter = Remitters::Resolver.call(
        telegram_user_id: @transaction.telegram_message&.telegram_sender_id,
        telegram_username: @transaction.telegram_message&.telegram_username
      ).remitter

      Result.new(status: :identified, merchant:, merchant_dealer: link, remitter:, issue: nil)
    end

    private

    def unidentified(issue, merchant)
      Result.new(status: :unidentified, merchant:, merchant_dealer: nil, remitter: nil, issue:)
    end

    def ocr_merchant_name
      @transaction.extraction["merchant_name"].to_s
    end
  end
end
