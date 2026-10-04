import { Controller } from "@hotwired/stimulus"

// Formats a VND amount with "." thousands separators while typing.
// The server strips separators, so the submitted value stays exact.
export default class extends Controller {
  connect() {
    this.format()
  }

  format() {
    const digits = this.element.value.replace(/\D/g, "")
    this.element.value = digits.replace(/\B(?=(\d{3})+(?!\d))/g, ".")
  }
}
