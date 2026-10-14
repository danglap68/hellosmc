require "openssl"
require "uri"

module Telegram
  class MiniAppAuth
    class Invalid < StandardError; end

    def self.call(init_data, token: AppConfig.telegram_bot_token)
      raise Invalid, "Mở trang này từ Telegram để xác thực." if token.blank? || init_data.to_s.blank? || init_data.to_s.bytesize > 16_384

      pairs = URI.decode_www_form(init_data.to_s)
      raise Invalid, "Dữ liệu xác thực không hợp lệ." unless pairs.map(&:first).uniq.size == pairs.size

      fields = pairs.to_h
      supplied_hash = fields.delete("hash").to_s
      data_check = fields.sort.map { |key, value| "#{key}=#{value}" }.join("\n")
      secret = OpenSSL::HMAC.digest("SHA256", "WebAppData", token)
      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, data_check)
      raise Invalid, "Chữ ký Telegram không hợp lệ." unless supplied_hash.match?(/\A[0-9a-f]{64}\z/) &&
        ActiveSupport::SecurityUtils.secure_compare(expected, supplied_hash)

      timestamp = Integer(fields.fetch("auth_date"), 10)
      raise Invalid, "Phiên Telegram đã hết hạn. Hãy mở lại từ nhóm." unless timestamp.between?(1.hour.ago.to_i, Time.current.to_i + 30)

      user = JSON.parse(fields.fetch("user"))
      raise Invalid, "Không xác định được người dùng Telegram." unless user.is_a?(Hash) && user["id"].is_a?(Integer) && user["id"].positive?

      { user_id: user.fetch("id"), start_param: fields.fetch("start_param") }
    rescue ArgumentError, KeyError, JSON::ParserError
      raise Invalid, "Dữ liệu xác thực không hợp lệ."
    end
  end
end
