module Telegram
  # Group naming template: "TenDaiLy-HKD1-HKD2" (HKD2 optional).
  #   "Anh Trân-Thiên Kim GV-Cherry Cofee" → agent "Anh Trân", HKDs ["Thiên Kim GV", "Cherry Cofee"].
  # Only splits the text; matching tokens to records happens in TelegramChat.
  module ChatNameParser
    Result = Data.define(:agent_token, :merchant_tokens) do
      def present?
        agent_token.present?
      end
    end

    SEPARATOR = /\s*[-–—]\s*/

    module_function

    def call(name)
      parts = name.to_s.split(SEPARATOR).map(&:strip).reject(&:blank?)
      Result.new(agent_token: parts.first, merchant_tokens: parts.drop(1))
    end
  end
end
