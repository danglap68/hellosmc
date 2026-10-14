module PaymentQrs
  # Read the recipient from a VietQR payload, never from OCR or a QR URL.
  # Lengths and CRC use bytes, as required by the EMV TLV format.
  class RecipientParser
    def self.call(payload)
      new(payload).call
    end

    def initialize(payload)
      @payload = payload.is_a?(String) ? payload.b : "".b
    end

    def call
      raise Error, "Mã QR không phải VietQR chuyển khoản hợp lệ." unless @payload.bytesize.between?(40, 2048) &&
        @payload.match?(/6304[0-9A-Fa-f]{4}\z/n)
      fields = parse(@payload)
      expected = Vietqr.crc16(@payload.byteslice(0, @payload.bytesize - 4))
      raise Error, "Dữ liệu QR bị lỗi. Hãy tải lại ảnh QR gốc rõ nét." unless fields["63"]&.upcase == expected
      raise Error, "QR này không phải mã chuyển khoản VietQR (VND)." unless fields["00"] == "01" && fields["53"] == "704" && fields["58"] == "VN"

      merchant = parse(fields.fetch("38", ""))
      raise Error, "QR này không phải mã chuyển khoản tới tài khoản ngân hàng. Hãy dùng QR nhận tiền của tài khoản." unless merchant["00"] == "A000000727" && merchant["02"] == "QRIBFTTA"

      account = parse(merchant.fetch("01", ""))
      bin, number = account.values_at("00", "01")
      raise Error, "Ngân hàng trong QR chưa có trong danh mục VietQR." unless Banks.name(bin)
      raise Error, "Số tài khoản trong QR không hợp lệ." unless number&.match?(/\A[a-zA-Z0-9]{1,19}\z/n)

      holder = fields["59"]&.dup&.force_encoding(Encoding::UTF_8)
      raise Error, "Tên người nhận trong QR không hợp lệ." if holder && !holder.valid_encoding?

      holder = holder&.squish
      holder = nil if holder.blank? || holder.upcase.in?(%w[NA N/A VIETQR NAPAS])
      if holder && (!holder.valid_encoding? || holder.length > 100 || holder.match?(/[[:cntrl:]]/))
        raise Error, "Tên người nhận trong QR không hợp lệ."
      end
      { "bank_bin" => bin, "bank_name" => Banks.name(bin), "bank_account_number" => number,
        "bank_account_name" => holder, "name_source" => holder ? "qr" : nil }
    end

    private

    def parse(bytes)
      fields = {}
      offset = 0
      while offset < bytes.bytesize
        header = bytes.byteslice(offset, 4)
        raise Error, "Cấu trúc dữ liệu QR không hợp lệ." unless header&.match?(/\A\d{4}\z/n)

        tag, length = header.byteslice(0, 2), header.byteslice(2, 2).to_i
        raise Error, "Cấu trúc dữ liệu QR không hợp lệ." if fields.key?(tag) || offset + 4 + length > bytes.bytesize

        fields[tag] = bytes.byteslice(offset + 4, length)
        offset += 4 + length
      end
      fields
    end
  end
end
