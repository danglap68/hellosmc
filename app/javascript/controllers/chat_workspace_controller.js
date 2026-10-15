import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["info", "infoToggle"]
  static values = { infoOpen: Boolean }

  connect() {
    if (this.infoOpenValue) this.setInfo(true)
  }

  toggleInfo() {
    if (this.hasInfoTarget) this.setInfo(this.infoTarget.hidden)
  }

  closeInfo() {
    if (!this.hasInfoTarget || this.infoTarget.hidden) return

    this.setInfo(false)
    this.infoToggleTarget.focus()
  }

  setInfo(open) {
    this.infoTarget.hidden = !open
    this.infoToggleTarget.setAttribute("aria-expanded", String(open))
    if (open) this.infoTarget.querySelector("button").focus()
  }
}
