import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["toggle", "menu"]

  connect() {
    this.resetBeforeCache = () => this.reset()
    document.addEventListener("turbo:before-cache", this.resetBeforeCache)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.resetBeforeCache)
  }

  backdrop(event) {
    if (event.target === this.element) this.close()
  }

  escape(event) {
    if (event.key !== "Escape" || document.querySelector(".palette:not([hidden])")) return
    this.close()
  }

  close() {
    if (!this.menuTarget.classList.contains("show")) return
    const collapse = window.tabler?.Collapse
    if (collapse) collapse.getOrCreateInstance(this.menuTarget, { toggle: false }).hide()
    else this.reset()
  }

  // Turbo snapshots the page before leaving it; an open menu would reappear on back navigation.
  reset() {
    this.menuTarget.classList.remove("show", "collapsing")
    this.menuTarget.style.height = ""
    this.toggleTarget.classList.add("collapsed")
    this.toggleTarget.setAttribute("aria-expanded", "false")
  }
}
