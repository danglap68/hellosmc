import { Controller } from "@hotwired/stimulus"

// Zoom and rotate a bill image while reviewing it. In an album, clicking a
// photo of the strip shows it in the main viewer.
export default class extends Controller {
  static targets = ["image", "original"]

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

  show(event) {
    const src = event.params.src
    if (!src) return

    this.imageTarget.src = src
    if (this.hasOriginalTarget) this.originalTarget.href = src
    this.element.querySelectorAll(".album-thumb").forEach((thumb) => thumb.classList.toggle("active", thumb === event.currentTarget))
    this.reset()
  }

  apply() {
    this.imageTarget.style.transform = `scale(${this.scale}) rotate(${this.rotation}deg)`
  }
}
