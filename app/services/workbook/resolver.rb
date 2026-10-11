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
      chat = @transaction.bill_image&.telegram_chat
      merchant = @transaction.merchant || sole_chat_merchant(chat)
      return unidentified("merchant_missing", merchant) unless merchant

      # Agent TID comes only from the OCR merchant name; terminal_or_merchant_id
      # is a merchant identifier (MID) and does not tell which agent to use.
      # The Telegram group title may name the agent too; Dealers::Resolver
      # applies both hints and rejects a disagreement.
      tid_key = TidParser.call(ocr_merchant_name)
      dealer_result = Dealers::Resolver.call(merchant:, merchant_name: ocr_merchant_name, chat:,
                                                  recipient_name: @transaction.extraction["recipient_name"])
      link = dealer_result.merchant_dealer
      unless link
        return unidentified("agent_group_mismatch", merchant) if dealer_result.issue == "dealer_group_mismatch"
        return unidentified("agent_recipient_mismatch", merchant) if dealer_result.issue == "dealer_recipient_mismatch"
        return unidentified("agent_tid_missing", merchant) if tid_key.blank?

        return unidentified("agent_tid_unmapped", merchant)
      end

      # Remitter feature off: no remitter, so the thu chi report is not written.
      remitter =
        if AppConfig.remitter_features_enabled?
          Remitters::Resolver.call(
            telegram_user_id: @transaction.telegram_message&.telegram_sender_id,
            telegram_username: @transaction.telegram_message&.telegram_username
          ).remitter
        end

      Result.new(status: :identified, merchant:, merchant_dealer: link, remitter:, issue: nil)
    end

    private

    # With several HKDs in the group the fallback would be a guess.
    def sole_chat_merchant(chat)
      merchants = chat&.merchants&.limit(2).to_a
      merchants.one? ? merchants.first : nil
    end

    def unidentified(issue, merchant)
      Result.new(status: :unidentified, merchant:, merchant_dealer: nil, remitter: nil, issue:)
    end

    def ocr_merchant_name
      @transaction.extraction["merchant_name"].to_s
    end
  end
end
