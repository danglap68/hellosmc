import { Controller } from "@hotwired/stimulus"

// Highlights the Cài đặt section that matches the URL hash.
export default class extends Controller {
  connect() {
    this.mark = this.mark.bind(this)
    this.mark()
    window.addEventListener("hashchange", this.mark)
  }

  disconnect() {
    window.removeEventListener("hashchange", this.mark)
  }

  mark() {
    const hash = window.location.hash || "#ket-noi"
    this.element.querySelectorAll("a[href*='#']").forEach((link) => {
      if (link.hash === hash) link.setAttribute("aria-current", "page")
      else link.removeAttribute("aria-current")
    })
  }
}
