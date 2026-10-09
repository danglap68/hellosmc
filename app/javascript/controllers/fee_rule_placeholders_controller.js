import { Controller } from "@hotwired/stimulus"

// Phí gốc giữ gợi ý mức sheet. Phí gốc theo thẻ chỉ hiện khi đã chọn loại thẻ.
// MB và Napas: phí gốc theo thẻ 0,88 / phí đại lý 1,2. Các loại khác: 1,21 / 1,4.
const SPECIAL_KEYS = new Set(["mb", "napas"])

export default class extends Controller {
  static targets = ["cardType", "baseFee", "cardBaseField", "cardBaseFee", "dealerFee"]

  connect() {
    this.apply()
  }

  apply() {
    const keys = Array.from(this.cardTypeTarget.querySelectorAll("input:checked")).map((input) => input.dataset.key).filter(Boolean)
    const special = keys.length > 0 && keys.every((key) => SPECIAL_KEYS.has(key))
    this.baseFeeTarget.placeholder = "1,21"
    this.cardBaseFeeTarget.placeholder = special ? "0,88" : "1,21"
    this.dealerFeeTarget.placeholder = special ? "1,2" : "1,4"
    this.cardBaseFieldTarget.classList.toggle("d-none", keys.length === 0)
    if (keys.length === 0) this.cardBaseFeeTarget.value = ""
  }
}
