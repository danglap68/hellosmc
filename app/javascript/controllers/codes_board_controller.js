import { Controller } from "@hotwired/stimulus"

// Filters the public code board as someone types, switches person/HKD
// grouping, and copies one mã. Clipboard API first, then a selection
// fallback so mobile Safari still copies on a tap.
export default class extends Controller {
  static targets = [ "board", "query", "empty", "live", "groupButton", "groupField", "bar", "clear" ]
  static values = {
    group: { type: String, default: "person" },
    copied: String,
    failed: String
  }

  connect() {
    this.syncBar()
    if (this.hasBarTarget && typeof ResizeObserver !== "undefined") {
      this.barObserver = new ResizeObserver(() => this.syncBar())
      this.barObserver.observe(this.barTarget)
    }
    this.apply()
  }

  disconnect() {
    this.barObserver?.disconnect()
    clearTimeout(this.copiedTimer)
  }

  clearQuery(event) {
    event.preventDefault()
    if (this.hasQueryTarget) {
      this.queryTarget.value = ""
      this.queryTarget.focus()
    }
    this.apply()
  }

  filter() {
    this.apply()
  }

  submit(event) {
    event.preventDefault()
    this.apply()
  }

  showGroup(event) {
    event.preventDefault()
    const group = event.currentTarget.dataset.group
    if (group !== "person" && group !== "hkd") return
    this.groupValue = group
    this.apply()
  }

  copy(event) {
    const button = event.currentTarget
    const code = button.dataset.code
    if (!code) return

    const pending = window.isSecureContext && navigator.clipboard?.writeText
      ? navigator.clipboard.writeText(code)
      : null

    if (pending) {
      pending.then(() => this.mark(button, "is-copied", this.copiedValue, `${this.copiedValue} ${code}`)).catch(() => {
        this.finishLegacy(button, code)
      })
      return
    }

    this.finishLegacy(button, code)
  }

  apply() {
    const raw = this.hasQueryTarget ? this.queryTarget.value : ""
    const query = this.normalize(raw)
    let shown = 0
    if (this.hasClearTarget) {
      const blank = raw.trim() === ""
      this.clearTarget.disabled = blank
      this.clearTarget.classList.toggle("is-idle", blank)
      this.clearTarget.setAttribute("aria-hidden", String(blank))
    }

    this.boardTargets.forEach((board) => {
      const active = board.dataset.group === this.groupValue
      board.hidden = !active
      if (!active) return

      board.querySelectorAll("[data-code-card]").forEach((card) => {
        const match = query === "" || (card.dataset.search || "").includes(query)
        card.hidden = !match
        if (match) shown += 1
      })
      board.querySelectorAll("[data-code-group]").forEach((group) => {
        group.hidden = !group.querySelector("[data-code-card]:not([hidden])")
      })
    })

    if (this.hasEmptyTarget) this.emptyTarget.hidden = shown > 0
    this.groupButtonTargets.forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.group === this.groupValue))
    })
    if (this.hasGroupFieldTarget) this.groupFieldTarget.value = this.groupValue === "hkd" ? "hkd" : ""
    this.remember()
  }

  finishLegacy(button, code) {
    if (this.legacyCopy(code)) {
      this.mark(button, "is-copied", this.copiedValue, `${this.copiedValue} ${code}`)
      return
    }
    this.mark(button, "is-failed", this.failedValue, `${this.failedValue} ${code}`)
    this.selectCode(button)
  }

  mark(button, state, label, announcement) {
    if (this.copiedButton && this.copiedButton !== button) this.clearStatus(this.copiedButton)
    clearTimeout(this.copiedTimer)
    this.clearStatus(button)
    button.classList.add(state)
    const status = button.querySelector("[data-copy-label]")
    if (status) status.textContent = label
    if (this.hasLiveTarget) this.liveTarget.textContent = announcement
    this.copiedButton = button
    this.copiedTimer = setTimeout(() => this.clearStatus(button), 2000)
  }

  clearStatus(button) {
    button.classList.remove("is-copied", "is-failed")
    const status = button.querySelector("[data-copy-label]")
    if (status) status.textContent = ""
  }

  syncBar() {
    if (!this.hasBarTarget) return
    this.element.style.setProperty("--codes-bar-h", `${Math.ceil(this.barTarget.getBoundingClientRect().height)}px`)
  }

  legacyCopy(text) {
    const field = document.createElement("textarea")
    field.value = text
    field.setAttribute("readonly", "")
    field.setAttribute("aria-hidden", "true")
    field.style.cssText = "position:fixed;top:0;left:0;width:1px;height:1px;padding:0;border:0;font-size:16px;opacity:0;"
    document.body.appendChild(field)
    field.focus()
    field.select()
    field.setSelectionRange(0, text.length)
    let ok = false
    try {
      ok = document.execCommand("copy")
    } catch (_error) {
      ok = false
    }
    field.remove()
    return ok
  }

  selectCode(button) {
    const code = button.querySelector("[data-code-text]")
    const selection = window.getSelection()
    if (!code || !selection) return
    const range = document.createRange()
    range.selectNodeContents(code)
    selection.removeAllRanges()
    selection.addRange(range)
  }

  remember() {
    const url = new URL(window.location.href)
    const raw = this.hasQueryTarget ? this.queryTarget.value : ""
    if (raw.trim()) url.searchParams.set("q", raw)
    else url.searchParams.delete("q")
    if (this.groupValue === "hkd") url.searchParams.set("nhom", "hkd")
    else url.searchParams.delete("nhom")
    const next = `${url.pathname}${url.search}`
    if (`${window.location.pathname}${window.location.search}` !== next) {
      window.history.replaceState(null, "", next)
    }
  }

  // Same folding as VietnameseText.normalize, so "Sơn" matches data-search "son".
  normalize(text) {
    return text
      .toString()
      .replace(/đ/g, "d")
      .replace(/Đ/g, "D")
      .normalize("NFD")
      .replace(/\p{Mn}/gu, "")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, " ")
      .trim()
      .replace(/\s+/g, " ")
  }
}
