import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "input", "list", "hint"]
  static values = { items: Array, labels: Object }

  connect() {
    this.onKeydown = this.onKeydown.bind(this)
    document.addEventListener("keydown", this.onKeydown)
    this.index = 0
    this.rows = []
    if (this.hasHintTarget && !/Mac|iPhone|iPad/.test(navigator.platform)) this.hintTarget.textContent = "Ctrl K"
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
  }

  onKeydown(event) {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault()
      this.open()
      return
    }
    if (!this.openDialog()) return
    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
    } else if (event.key === "ArrowDown") {
      event.preventDefault()
      this.move(1)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.move(-1)
    } else if (event.key === "Enter") {
      event.preventDefault()
      this.rows[this.index]?.click()
    }
  }

  open() {
    this.dialogTarget.hidden = false
    this.inputTarget.value = ""
    this.index = 0
    this.render("")
    this.inputTarget.focus()
  }

  close() {
    this.dialogTarget.hidden = true
  }

  backdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }

  filter() {
    this.index = 0
    this.render(this.inputTarget.value)
  }

  remember(event) {
    const url = event.currentTarget.getAttribute("href")
    if (!url) return
    const recent = this.recent().filter((item) => item !== url)
    recent.unshift(url)
    try {
      localStorage.setItem("smc-command-recent", JSON.stringify(recent.slice(0, 6)))
    } catch {
      // Recent pages still work for this visit when storage is blocked.
    }
  }

  openDialog() {
    return this.hasDialogTarget && !this.dialogTarget.hidden
  }

  move(step) {
    if (this.rows.length === 0) return
    this.index = Math.max(0, Math.min(this.rows.length - 1, this.index + step))
    this.mark()
  }

  render(query) {
    const labels = this.labelsValue
    const normalized = query.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/đ/g, "d").replace(/[^a-z0-9]+/g, " ").trim()
    const matches = this.itemsValue.filter((item) => normalized === "" || item.search.includes(normalized))
    this.listTarget.replaceChildren()
    this.rows = []
    if (matches.length === 0) {
      const empty = document.createElement("p")
      empty.className = "palette-empty"
      empty.textContent = labels.empty
      this.listTarget.append(empty)
      return
    }

    const recentUrls = normalized === "" ? this.recent() : []
    const recent = recentUrls.map((url) => matches.find((item) => item.url === url)).filter(Boolean)
    const seen = new Set(recent.map((item) => item.url))
    this.appendGroup(labels.recent, recent)
    this.appendGroup(labels.pages, matches.filter((item) => item.group === "pages" && !seen.has(item.url)))
    this.appendGroup(labels.actions, matches.filter((item) => item.group === "actions"))
    this.mark()
  }

  appendGroup(title, items) {
    if (items.length === 0) return
    const heading = document.createElement("div")
    heading.className = "palette-group"
    heading.textContent = title
    this.listTarget.append(heading)
    items.forEach((item) => {
      const link = document.createElement("a")
      link.className = "palette-row"
      link.href = item.url
      link.dataset.action = "click->command-palette#remember"
      const label = document.createElement("span")
      label.className = "palette-label"
      label.textContent = item.label
      const hint = document.createElement("span")
      hint.className = "palette-hint"
      hint.textContent = item.hint
      link.append(label, hint)
      this.listTarget.append(link)
      this.rows.push(link)
    })
  }

  mark() {
    this.rows.forEach((row, index) => row.classList.toggle("is-active", index === this.index))
    this.rows[this.index]?.scrollIntoView({ block: "nearest" })
  }

  recent() {
    try {
      const parsed = JSON.parse(localStorage.getItem("smc-command-recent") || "[]")
      return Array.isArray(parsed) ? parsed.filter((item) => typeof item === "string") : []
    } catch {
      return []
    }
  }
}
