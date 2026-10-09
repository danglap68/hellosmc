import { Controller } from "@hotwired/stimulus"

// Nút dropdown hiện các mục đã tick. Danh sách bên trong giữ mở để tick nhiều mục.
export default class extends Controller {
  static targets = ["summary"]
  static values = { empty: String }

  connect() {
    this.refresh()
  }

  refresh() {
    const names = Array.from(this.element.querySelectorAll("input:checked")).map((input) => {
      return input.closest("label")?.innerText.trim() || ""
    }).filter(Boolean)

    this.summaryTarget.textContent = names.length ? names.join(", ") : this.emptyValue
  }
}
