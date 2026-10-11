import { Controller } from "@hotwired/stimulus"

// Shows the column list that matches the export type selected on the form.
export default class extends Controller {
  static targets = ["layout", "panel"]

  connect() {
    this.apply()
  }

  apply() {
    const layout = this.layoutTarget.value
    this.panelTargets.forEach((panel) => {
      panel.hidden = panel.dataset.layout !== layout
    })
  }
}
