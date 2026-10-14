module PaymentQrs
  # NAPAS VietQR, credit transfer to a bank account. Generate locally so no
  # account number or amount is sent to an external image service.
  class Vietqr
    def self.payload(bank_bin:, account_number:, amount:, memo:)
      raise ArgumentError, "Ngân hàng không hợp lệ" unless Banks.name(bank_bin)
      raise ArgumentError, "Số tài khoản không hợp lệ" unless account_number.to_s.match?(/\A[a-zA-Z0-9]{1,19}\z/)
      raise ArgumentError, "Số tiền phải là số nguyên dương, tối đa 13 chữ số" unless amount.to_s.match?(/\A[1-9]\d{0,12}\z/)
      raise ArgumentError, "Mã chuyển tiền không hợp lệ" unless memo.to_s.match?(/\A[A-Z]+\d+\z/) && memo.bytesize <= 25

      account = tlv("00", bank_bin) + tlv("01", account_number)
      merchant = tlv("00", "A000000727") + tlv("01", account) + tlv("02", "QRIBFTTA")
      content = tlv("00", "01") + tlv("01", "12") + tlv("38", merchant) + tlv("53", "704") +
                tlv("54", amount.to_s) + tlv("58", "VN") + tlv("62", tlv("08", memo)) + "6304"
      content + crc16(content)
    end

    def self.png(payload)
      RQRCode::QRCode.new(payload).as_png(size: 480, border_modules: 4, color: "black", fill: "white").to_s
    end

    def self.tlv(id, value)
      raise ArgumentError, "Trường QR quá dài" if value.bytesize > 99

      "#{id}#{format('%02d', value.bytesize)}#{value}"
    end
    private_class_method :tlv

    def self.crc16(value)
      crc = 0xFFFF
      value.each_byte do |byte|
        crc ^= byte << 8
        8.times { crc = ((crc << 1) ^ ((crc & 0x8000).zero? ? 0 : 0x1021)) & 0xFFFF }
      end
      format("%04X", crc)
    end
  end
end
