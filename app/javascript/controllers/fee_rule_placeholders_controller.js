import { Controller } from "@hotwired/stimulus"

// Gợi ý mức phí trên form quy tắc phí theo loại thẻ đang chọn.
// MB và Napas: phí gốc 0,88 / phí đại lý 1,2. Các loại khác, kể cả để trống: 1,21 / 1,4.
const SPECIAL_KEYS = new Set(["mb", "napas"])

export default class extends Controller {
  static targets = ["cardType", "baseFee", "dealerFee"]

  connect() {
    this.apply()
  }

  apply() {
    const key = this.cardTypeTarget.selectedOptions[0]?.dataset.key
    const special = SPECIAL_KEYS.has(key)
    this.baseFeeTarget.placeholder = special ? "0,88" : "1,21"
    this.dealerFeeTarget.placeholder = special ? "1,2" : "1,4"
  }
}
