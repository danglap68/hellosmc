module RecipientQrFixtures
  def recipient_qr_payload(holder: nil, account: "0011001932418", bank: "970415", service: "QRIBFTTA", currency: "704", extra: "")
    account_fields = qr_tlv("00", bank) + qr_tlv("01", account)
    recipient = qr_tlv("00", "A000000727") + qr_tlv("01", account_fields) + qr_tlv("02", service)
    root = qr_tlv("00", "01") + qr_tlv("01", "11") + qr_tlv("38", recipient) + qr_tlv("53", currency) +
           qr_tlv("54", "92500") + qr_tlv("58", "VN")
    root += qr_tlv("59", holder) if holder
    root += qr_tlv("62", qr_tlv("08", "DO NOT IMPORT THIS MEMO")) + extra + "6304"
    root + PaymentQrs::Vietqr.crc16(root)
  end

  def qr_tlv(tag, value)
    tag + format("%02d", value.bytesize) + value
  end
end
