import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "form", "method", "title", "note"]

  open(event) {
    const trigger = event.currentTarget
    this.trigger = trigger
    this.formTarget.action = trigger.dataset.rejectionUrl
    this.methodTarget.disabled = trigger.dataset.rejectionMethod !== "patch"
    this.titleTarget.textContent = trigger.dataset.rejectionTitle
    const draft = trigger.form?.elements.namedItem("note")?.value
    this.noteTarget.value = draft?.trim() ? draft : trigger.dataset.rejectionReason
    this.dialogTarget.showModal()
    this.noteTarget.focus()
    this.noteTarget.setSelectionRange(this.noteTarget.value.length, this.noteTarget.value.length)
  }

  close() {
    if (this.dialogTarget.open) this.dialogTarget.close()
  }

  closed() {
    this.formTarget.reset()
    this.trigger?.focus()
  }
}
