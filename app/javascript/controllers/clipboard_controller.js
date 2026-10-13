import { Controller } from "@hotwired/stimulus"

// Copies data-clipboard-text-value and briefly swaps the copy icon for a
// check. Clipboard API first, then a hidden-textarea fallback for plain http.
export default class extends Controller {
  static values = { text: String, copied: String, toast: String }

  disconnect() {
    clearTimeout(this.timer)
  }

  copy(event) {
    event.preventDefault()
    if (!this.textValue) return

    if (window.isSecureContext && navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(this.textValue).then(() => this.done(), () => this.fallback())
    } else {
      this.fallback()
    }
  }

  fallback() {
    const field = document.createElement("textarea")
    field.value = this.textValue
    field.setAttribute("readonly", "")
    field.style.cssText = "position:fixed;top:0;left:0;opacity:0;font-size:16px;"
    document.body.appendChild(field)
    field.select()
    let ok = false
    try {
      ok = document.execCommand("copy")
    } catch (_error) {
      ok = false
    }
    field.remove()
    if (ok) this.done()
  }

  done() {
    clearTimeout(this.timer)
    this.label ??= this.element.getAttribute("title")
    this.toggle(true)
    this.timer = setTimeout(() => this.toggle(false), 1500)
    if (this.toastValue) {
      window.dispatchEvent(new CustomEvent("toast:show", { detail: { type: "success", message: this.toastValue } }))
    }
  }

  toggle(copied) {
    const icon = this.element.querySelector(".ti")
    icon?.classList.toggle("ti-copy", !copied)
    icon?.classList.toggle("ti-check", copied)
    this.element.classList.toggle("text-success", copied)
    this.element.setAttribute("title", copied ? this.copiedValue : this.label)
  }
}
