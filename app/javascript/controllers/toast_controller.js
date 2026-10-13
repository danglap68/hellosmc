import { Controller } from "@hotwired/stimulus"

const MAX_VISIBLE = 4
const LEAVE_MS = 180

// Toast stack. Server toasts come from flash; client code shows one with
//   window.dispatchEvent(new CustomEvent("toast:show", { detail: { type: "success", message: "…" } }))
// Hovering or focusing a toast pauses its auto-dismiss timer.
export default class extends Controller {
  static targets = ["item", "template"]
  static values = { types: Object }

  initialize() {
    this.timers = new WeakMap()
  }

  itemTargetConnected(item) {
    const duration = Number(item.dataset.duration)
    if (duration > 0) {
      item.style.setProperty("--toast-duration", `${duration}ms`)
      item.classList.add("has-timer")
      this.timers.set(item, { remaining: duration })
      this.start(item)
    }
    this.trim()
  }

  itemTargetDisconnected(item) {
    clearTimeout(this.timers.get(item)?.id)
  }

  show(event) {
    const { type = "info", message } = event.detail || {}
    if (!message || !this.hasTemplateTarget) return

    const config = this.typesValue[type] ? type : "info"
    const { icon, title, duration, role } = this.typesValue[config]
    const item = this.templateTarget.content.firstElementChild.cloneNode(true)
    item.className = `app-toast app-toast-${config}`
    item.setAttribute("role", role)
    item.dataset.duration = duration
    item.querySelector(".app-toast-icon .ti").className = `ti ti-${icon} icon`
    item.querySelector(".app-toast-title").textContent = title
    item.querySelector(".app-toast-message").textContent = message
    this.element.appendChild(item)
  }

  dismiss(event) {
    const item = event.target.closest(".app-toast")
    if (item) this.remove(item)
  }

  pause(event) {
    const item = event.currentTarget
    const timer = this.timers.get(item)
    if (!timer?.id) return

    clearTimeout(timer.id)
    timer.id = null
    timer.remaining -= Date.now() - timer.startedAt
    item.classList.add("is-paused")
  }

  resume(event) {
    const item = event.currentTarget
    const timer = this.timers.get(item)
    if (!timer || timer.id) return
    const focusInside = event.type === "focusout" ? item.contains(event.relatedTarget) : item.contains(document.activeElement)
    if (item.matches(":hover") || focusInside) return

    item.classList.remove("is-paused")
    this.start(item)
  }

  start(item) {
    const timer = this.timers.get(item)
    timer.startedAt = Date.now()
    timer.id = setTimeout(() => this.remove(item), Math.max(timer.remaining, 0))
  }

  remove(item) {
    if (item.classList.contains("is-leaving")) return

    clearTimeout(this.timers.get(item)?.id)
    item.classList.add("is-leaving")
    setTimeout(() => item.remove(), LEAVE_MS)
  }

  trim() {
    const visible = this.itemTargets.filter((item) => !item.classList.contains("is-leaving"))
    visible.slice(0, Math.max(visible.length - MAX_VISIBLE, 0)).forEach((item) => this.remove(item))
  }
}
