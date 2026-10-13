import { Controller } from "@hotwired/stimulus"

// Popover for the shared list toolbar. Filter edits stay in the form until
// Áp dụng. Search and sort are separate submits so a half-finished filter
// is not applied by accident.
export default class extends Controller {
  static targets = ["panel", "sortMenu", "filterButton", "sortButton", "categoryList", "detail", "detailTitle", "detailBody"]

  connect() {
    this.onDocumentClick = (event) => {
      if (!this.element.contains(event.target)) this.closeMenus()
    }
    this.onKeydown = (event) => {
      if (event.key === "Escape") this.closeMenus()
    }
    document.addEventListener("click", this.onDocumentClick)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("click", this.onDocumentClick)
    document.removeEventListener("keydown", this.onKeydown)
  }

  togglePanel(event) {
    event.preventDefault()
    const opening = this.panelTarget.hidden
    this.closeMenus()
    if (!opening) return

    this.panelTarget.hidden = false
    this.filterButtonTarget.setAttribute("aria-expanded", "true")
    this.showCategories()
  }

  toggleSort(event) {
    event.preventDefault()
    const opening = this.sortMenuTarget.hidden
    this.closeMenus()
    if (!opening) return

    this.sortMenuTarget.hidden = false
    this.sortButtonTarget.setAttribute("aria-expanded", "true")
  }

  openCategory(event) {
    event.preventDefault()
    const key = event.currentTarget.dataset.category
    this.categoryListTarget.hidden = true
    this.detailTarget.hidden = false
    this.detailTitleTarget.textContent = event.currentTarget.dataset.label
    this.detailBodyTargets.forEach((body) => {
      body.hidden = body.dataset.category !== key
    })
  }

  showCategories(event) {
    event?.preventDefault()
    this.detailTarget.hidden = true
    this.categoryListTarget.hidden = false
  }

  resetFilters(event) {
    event.preventDefault()
    this.panelTarget.querySelectorAll("[data-filter-control]").forEach((field) => {
      if (field.type === "checkbox") {
        field.checked = false
      } else if (field.type === "radio") {
        field.checked = field.value === ""
      } else {
        field.value = ""
      }
    })
  }

  compact(event) {
    event.target.querySelectorAll("input, select, textarea").forEach((field) => {
      if (field.type === "submit" || field.type === "button" || field.type === "hidden") return
      const empty = field.type === "radio" || field.type === "checkbox" ? field.checked && field.value === "" : field.value === ""
      if (!empty) return

      field.disabled = true
      field.dataset.compacted = "true"
    })
  }

  restore(event) {
    event.target.querySelectorAll("[data-compacted]").forEach((field) => {
      field.disabled = false
      delete field.dataset.compacted
    })
  }

  closeMenus() {
    if (this.hasPanelTarget) this.panelTarget.hidden = true
    if (this.hasSortMenuTarget) this.sortMenuTarget.hidden = true
    if (this.hasFilterButtonTarget) this.filterButtonTarget.setAttribute("aria-expanded", "false")
    if (this.hasSortButtonTarget) this.sortButtonTarget.setAttribute("aria-expanded", "false")
  }
}
