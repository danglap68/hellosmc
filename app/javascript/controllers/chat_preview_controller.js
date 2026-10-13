import { Controller } from "@hotwired/stimulus"

// Shows a chat photo on this page. The thread stays put; Escape or the
// dark area closes the preview.
export default class extends Controller {
  static targets = ["dialog", "image"]

  open(event) {
    const src = event.params.src
    if (!src || !this.hasDialogTarget) return

    this.imageTarget.src = src
    this.imageTarget.alt = ""
    if (!this.dialogTarget.open) this.dialogTarget.showModal()
  }

  close() {
    if (!this.hasDialogTarget || !this.dialogTarget.open) return

    this.dialogTarget.close()
  }

  closed() {
    if (this.hasImageTarget) this.imageTarget.removeAttribute("src")
  }

  backdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }
}
