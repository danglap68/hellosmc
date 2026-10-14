import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { selectedCsv } from "table_csv"

// One controller per table: selection never leaks across tables or pages.
export default class extends Controller {
  static values = { resource: String, operations: Array, labels: Object, url: String }

  connect() {
    if (document.documentElement.hasAttribute("data-turbo-preview")) return
    this.listeners = new AbortController()
    this.rows = Array.from(this.element.tBodies).flatMap(body => Array.from(body.rows))
      .filter(row => !Array.from(row.cells).some(cell => cell.colSpan > 1))
    if (!this.rows.length) return

    this.cells = []
    this.checkboxes = this.rows.map((row, index) => {
      const checkbox = this.checkbox(this.labelsValue.select_row.replace("%{row}", row.dataset.bulkId || index + 1))
      this.addCell(row, "td", checkbox)
      this.listen(checkbox, "change", () => this.update())
      return checkbox
    })
    this.generatedHead = !this.element.tHead
    const head = this.element.tHead || this.element.createTHead()
    const headerRow = head.rows[0] || head.insertRow()
    if (this.generatedHead) {
      Array.from(this.rows[0].cells).slice(1).forEach(() => headerRow.append(document.createElement("th")))
    }
    this.selectAll = this.checkbox(this.labelsValue.select_all)
    this.addCell(headerRow, "th", this.selectAll)
    this.listen(this.selectAll, "change", () => {
      this.checkboxes.forEach(checkbox => { checkbox.checked = this.selectAll.checked })
      this.update()
    })
    // Keep any totals aligned, but never include them in selection or CSV.
    if (this.element.tFoot) Array.from(this.element.tFoot.rows).forEach(row => this.addCell(row, "td"))

    this.toolbar = document.getElementById("bulk-table-toolbar").content.firstElementChild.cloneNode(true)
    const container = this.element.closest(".table-responsive") || this.element
    container.before(this.toolbar)
    this.listen(this.toolbar.querySelector("[data-bulk-clear]"), "click", () => {
      this.checkboxes.forEach(checkbox => { checkbox.checked = false })
      this.update()
    })
    this.listen(this.toolbar.querySelector("[data-bulk-export]"), "click", () => this.export())
    this.operationsValue.forEach(operation => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = `btn btn-sm ${["reject", "destroy"].includes(operation.key) ? "btn-outline-danger" : "btn-outline-primary"}`
      button.textContent = operation.label
      this.listen(button, "click", () => this.open(operation))
      this.toolbar.querySelector("[data-bulk-operations]").append(button)
    })
    this.listen(document, "turbo:before-cache", () => this.cleanup())
    this.update()
  }

  disconnect() { this.cleanup() }

  listen(element, event, handler) {
    element.addEventListener(event, handler, { signal: this.listeners.signal })
  }

  checkbox(label) {
    const input = document.createElement("input")
    input.type = "checkbox"
    input.className = "form-check-input bulk-checkbox"
    input.setAttribute("aria-label", label)
    return input
  }

  addCell(row, type, child) {
    const cell = document.createElement(type)
    cell.className = "bulk-select-cell"
    if (type === "th") cell.scope = "col"
    if (child) {
      const label = document.createElement("label")
      label.className = "bulk-check-hit"
      label.append(child)
      cell.append(label)
    }
    row.prepend(cell)
    this.cells.push(cell)
  }

  get selectedRows() { return this.rows.filter((row, index) => this.checkboxes[index].checked) }

  update() {
    const selected = this.selectedRows
    const count = selected.length
    this.toolbar.querySelector("[data-bulk-count]").textContent = this.labelsValue.selected.replace("%{count}", count)
    this.toolbar.classList.toggle("has-selection", count > 0)
    this.toolbar.querySelectorAll("button").forEach(button => { button.disabled = !count })
    this.toolbar.querySelectorAll("[data-bulk-operations] button").forEach(button => {
      button.disabled = !count || selected.some(row => !row.dataset.bulkId || !row.dataset.bulkVersion)
    })
    this.selectAll.checked = count === this.rows.length
    this.selectAll.indeterminate = count > 0 && count < this.rows.length
    this.selectAll.setAttribute("aria-checked", this.selectAll.indeterminate ? "mixed" : String(this.selectAll.checked))
    this.rows.forEach((row, index) => {
      row.classList.toggle("bulk-selected", this.checkboxes[index].checked)
      row.setAttribute("aria-selected", String(this.checkboxes[index].checked))
    })
  }

  open(operation) {
    this.dialog?.remove()
    this.completed = false
    this.operation = operation
    this.selection = this.selectedRows.slice()
    this.dialog = document.getElementById("bulk-table-dialog").content.firstElementChild.cloneNode(true)
    this.dialog.setAttribute("aria-label", operation.label)
    this.dialog.querySelector("[data-bulk-title]").textContent = operation.label
    this.dialog.querySelector("[data-bulk-hint]").textContent = this.labelsValue.confirm_hint
      .replace("%{action}", operation.label).replace("%{count}", this.selection.length)
    const note = this.dialog.querySelector("[data-bulk-note]")
    note.id = `bulk-note-${crypto.randomUUID()}`
    this.dialog.querySelector("[data-bulk-note-label]").htmlFor = note.id
    note.required = operation.key === "reject"
    this.dialog.querySelector("[data-bulk-note-group]").hidden = operation.key !== "reject"
    if (note.required) note.value = this.selection.filter(row => row.dataset.bulkReason)
      .map(row => `#${row.dataset.bulkId}: ${row.dataset.bulkReason}`).join("\n")
    if (["reject", "destroy"].includes(operation.key)) this.dialog.querySelector("[data-bulk-confirm]").className = "btn btn-danger"
    this.listen(this.dialog.querySelector("form"), "submit", event => this.submit(event))
    this.listen(this.dialog.querySelector("[data-bulk-cancel]"), "click", () => { if (!this.busy) this.dialog.close() })
    this.listen(this.dialog, "cancel", event => { if (this.busy) event.preventDefault() })
    this.listen(this.dialog, "close", () => {
      if (this.completed) Turbo.visit(window.location.href, { action: "replace" })
    })
    document.body.append(this.dialog)
    this.dialog.showModal()
    if (note.required) note.focus()
  }

  async submit(event) {
    event.preventDefault()
    if (this.busy || this.completed) return
    this.busy = true
    const confirm = this.dialog.querySelector("[data-bulk-confirm]")
    this.dialog.querySelectorAll("button").forEach(button => { button.disabled = true })
    confirm.textContent = this.labelsValue.processing
    this.dialog.setAttribute("aria-busy", "true")
    const result = this.dialog.querySelector("[data-bulk-result]")
    try {
      const response = await fetch(this.urlValue, {
        method: "POST", credentials: "same-origin", signal: this.listeners.signal,
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
        body: JSON.stringify({ resource: this.resourceValue, operation: this.operation.key,
          ids: this.selection.map(row => row.dataset.bulkId),
          versions: Object.fromEntries(this.selection.map(row => [row.dataset.bulkId, row.dataset.bulkVersion])),
          note: this.dialog.querySelector("[data-bulk-note]").value })
      })
      if (response.redirected || !response.headers.get("content-type")?.includes("application/json")) throw new Error(this.labelsValue.request_failed)
      const data = await response.json()
      result.replaceChildren(document.createTextNode(data.message || this.labelsValue.request_failed))
      if (response.ok) {
        this.completed = true
        this.dialog.querySelector("[data-bulk-note-group]").hidden = true
        const failures = (data.results || []).filter(row => !row.success)
        if (failures.length) {
          const list = document.createElement("ul")
          list.className = "bulk-failures mt-2 mb-0"
          failures.forEach(row => {
            const item = document.createElement("li")
            item.textContent = `#${row.id}: ${row.message}`
            list.append(item)
          })
          result.append(list)
        }
      }
    } catch (error) {
      result.textContent = this.labelsValue.request_failed
    } finally {
      this.busy = false
      if (!this.dialog?.isConnected) return
      this.dialog.removeAttribute("aria-busy")
      result.hidden = false
      result.focus()
      confirm.hidden = this.completed
      confirm.disabled = false
      confirm.textContent = this.labelsValue.confirm
      const cancel = this.dialog.querySelector("[data-bulk-cancel]")
      cancel.disabled = false
      cancel.textContent = this.completed ? this.labelsValue.refresh : this.labelsValue.cancel
    }
  }

  export() {
    const csv = selectedCsv(this.element, this.selectedRows)
    const url = URL.createObjectURL(new Blob(["\uFEFF", csv], { type: "text/csv;charset=utf-8" }))
    const link = document.createElement("a")
    link.href = url
    link.download = `smc-selected-${new Date().toISOString().slice(0, 10)}.csv`
    link.click()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  }

  cleanup() {
    this.listeners?.abort()
    this.toolbar?.remove()
    this.dialog?.remove()
    this.cells?.forEach(cell => cell.remove())
    if (this.generatedHead) this.element.tHead?.remove()
    this.rows?.forEach(row => { row.classList.remove("bulk-selected"); row.removeAttribute("aria-selected") })
  }
}
