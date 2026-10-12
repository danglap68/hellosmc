module Workbook
  # Picks the HKD and DS-MB agent (via TID) for a Hello SMC write. Remitters
  # are not part of a transaction (see RemitterTransfer).
  # The agent re-resolves by TID (not just transaction.dealer) because a dealer
  # like Chị Huệ owns several TIDs under one HKD; only tid_key picks the right row.
  class Resolver
    Result = Data.define(:status, :merchant, :merchant_dealer, :issue) do
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
      merchant = @transaction.merchant
      return unidentified("merchant_missing", merchant) unless merchant

      # Agent TID comes only from the OCR merchant name; terminal_or_merchant_id
      # is a merchant identifier (MID) and does not tell which agent to use.
      tid_key = TidParser.call(ocr_merchant_name)
      dealer_result = Dealers::Resolver.call(merchant:, merchant_name: ocr_merchant_name,
                                                  recipient_name: @transaction.extraction["recipient_name"])
      link = dealer_result.merchant_dealer
      unless link
        return unidentified("agent_recipient_mismatch", merchant) if dealer_result.issue == "dealer_recipient_mismatch"
        return unidentified("agent_tid_missing", merchant) if tid_key.blank?

        return unidentified("agent_tid_unmapped", merchant)
      end

      Result.new(status: :identified, merchant:, merchant_dealer: link, issue: nil)
    end

    private

    def unidentified(issue, merchant)
      Result.new(status: :unidentified, merchant:, merchant_dealer: nil, issue:)
    end

    def ocr_merchant_name
      @transaction.extraction["merchant_name"].to_s
    end
  end
end
