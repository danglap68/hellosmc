import { Controller } from "@hotwired/stimulus"

// Review form: the dealer list follows the HKD picked in the browser, so a
// reviewer who corrects the HKD can choose that HKD's agents. The chosen agent
// is kept when it also works for the new HKD.
export default class extends Controller {
  static targets = ["merchant", "dealer"]
  static values = { options: Object }

  refresh() {
    const options = this.optionsValue[this.merchantTarget.value] || this.optionsValue[""] || []
    const select = this.dealerTarget
    const current = select.value
    const blank = select.querySelector('option[value=""]')

    select.replaceChildren(...(blank ? [blank] : []))
    options.forEach(([label, id]) => select.add(new Option(label, id)))
    select.value = options.some(([, id]) => String(id) === current) ? current : ""
  }
}
