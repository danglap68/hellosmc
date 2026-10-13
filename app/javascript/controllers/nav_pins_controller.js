import { Controller } from "@hotwired/stimulus"

const ONE_YEAR = 60 * 60 * 24 * 365

export default class extends Controller {
  static targets = ["section", "pinned", "list", "empty"]
  static values = { cookie: String, labels: Object }

  toggle(event) {
    event.preventDefault()
    const key = event.params.key
    const keys = this.readKeys()
    const index = keys.indexOf(key)
    if (index >= 0) keys.splice(index, 1)
    else keys.push(key)

    this.writeKeys(keys)
    this.render(keys)
  }

  render(keys) {
    const rows = new Map(
      [...this.listTarget.querySelectorAll("[data-nav-pins-key]")].map((row) => [row.dataset.navPinsKey, row])
    )
    const pinnedKeys = keys.filter((key) => rows.has(key))

    this.pinnedTarget.replaceChildren(...pinnedKeys.map((key) => rows.get(key).cloneNode(true)))
    this.emptyTarget.hidden = pinnedKeys.length > 0

    this.element.querySelectorAll("[data-nav-pins-key]").forEach((row) => {
      this.paintStar(row, pinnedKeys.includes(row.dataset.navPinsKey))
    })
  }

  paintStar(row, pinned) {
    const button = row.querySelector(".shell-pin")
    if (!button) return

    const name = row.querySelector(".shell-link-label")?.textContent.trim() || ""
    button.setAttribute("aria-pressed", String(pinned))
    button.setAttribute("aria-label", (pinned ? this.labelsValue.unpin : this.labelsValue.pin).replace("%{name}", name))
    button.title = pinned ? this.labelsValue.unpin_short : this.labelsValue.pin_short
  }

  readKeys() {
    const raw = document.cookie.split("; ").find((part) => part.startsWith(`${this.cookieValue}=`))
    if (!raw) return []
    return decodeURIComponent(raw.split("=")[1] || "").split(",").filter(Boolean)
  }

  writeKeys(keys) {
    const value = encodeURIComponent(keys.join(","))
    document.cookie = `${this.cookieValue}=${value}; path=/; max-age=${ONE_YEAR}; SameSite=Lax`
  }
}
