import { Controller } from "@hotwired/stimulus"

// Manage includes read: turning manage on checks read, and turning read off
// clears manage. The server applies the same rule if this script does not run.
export default class extends Controller {
  sync(event) {
    const box = event.target
    if (!(box instanceof HTMLInputElement) || box.disabled) return

    const cell = box.closest("[data-role-matrix-cell]")
    if (!cell) return

    const read = cell.querySelector("[data-ability='read']")
    const manage = cell.querySelector("[data-ability='manage']")
    if (!read || !manage) return

    if (box === manage && manage.checked) read.checked = true
    if (box === read && !read.checked) manage.checked = false
  }
}
