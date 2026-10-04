import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Re-renders the current page after a delay while this element is on it,
// e.g. while an Excel export is still being generated. Replaces
// <meta http-equiv="refresh">: Turbo merges that tag into <head>, so every
// poll was a full reload and the browser's pending reload outlived Turbo
// navigation, pulling the user back to this page after they left.
export default class extends Controller {
  static values = { interval: { type: Number, default: 3000 } }

  connect() {
    if (document.documentElement.hasAttribute("data-turbo-preview")) return

    this.timer = setTimeout(() => Turbo.visit(window.location.href, { action: "replace" }), this.intervalValue)
  }

  disconnect() {
    this.stop()
  }

  // Bound to turbo:visit so a slow navigation away is not cancelled by a refresh.
  stop() {
    clearTimeout(this.timer)
  }
}
