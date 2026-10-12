import { Controller } from "@hotwired/stimulus"

// Recalculates the amounts under the review form while the amount is edited,
// with the rates saved on the transaction. Same arithmetic as
// Transactions::Calculator: amount * (1 - rate), half-up to whole VND, done
// with integers so no floating-point error creeps in. The server recalculates
// on save (and picks new rates if the merchant, agent or card type changed).
export default class extends Controller {
  static targets = ["amount", "afterBaseFee", "dealerAmount", "profit"]
  static values = { baseRate: String, dealerRate: String }

  update() {
    const digits = this.amountTarget.value.replace(/\D/g, "")
    if (!digits || /^0+$/.test(digits)) return this.show(null, null, null)

    const amount = BigInt(digits)
    const afterBaseFee = this.apply(amount, this.baseRateValue)
    const dealerAmount = this.dealerRateValue ? this.apply(amount, this.dealerRateValue) : null
    const profit = dealerAmount === null ? null : afterBaseFee - dealerAmount
    this.show(afterBaseFee, dealerAmount, profit)
  }

  // round_half_up(amount * (1 - rate)) where rate is a decimal string ("0.0121").
  apply(amount, rate) {
    const [whole, fraction = ""] = rate.split(".")
    const scale = 10n ** BigInt(fraction.length)
    const scaledRate = BigInt(whole + fraction)
    return (2n * amount * (scale - scaledRate) + scale) / (2n * scale)
  }

  show(afterBaseFee, dealerAmount, profit) {
    this.write("afterBaseFee", afterBaseFee)
    this.write("dealerAmount", dealerAmount)
    this.write("profit", profit)
  }

  write(name, value) {
    if (!this[`has${name[0].toUpperCase()}${name.slice(1)}Target`]) return
    this[`${name}Target`].textContent = value === null ? "—" : `${this.format(value)} ₫`
  }

  format(value) {
    return value.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".")
  }
}
