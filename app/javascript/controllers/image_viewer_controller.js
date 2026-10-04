import { Controller } from "@hotwired/stimulus"

// Zoom and rotate a bill image while reviewing it.
export default class extends Controller {
  static targets = ["image"]

  connect() {
    this.scale = 1
    this.rotation = 0
  }

  zoomIn() {
    this.scale = Math.min(this.scale + 0.25, 4)
    this.apply()
  }

  zoomOut() {
    this.scale = Math.max(this.scale - 0.25, 0.5)
    this.apply()
  }

  rotate() {
    this.rotation = (this.rotation + 90) % 360
    this.apply()
  }

  reset() {
    this.scale = 1
    this.rotation = 0
    this.apply()
  }

  apply() {
    this.imageTarget.style.transform = `scale(${this.scale}) rotate(${this.rotation}deg)`
  }
}
