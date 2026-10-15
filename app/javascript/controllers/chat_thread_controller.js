import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["log", "latest"]
  static values = { history: Boolean }

  connect() {
    this.followLatest = !this.historyValue
    this.frame = requestAnimationFrame(() => {
      if (this.followLatest) this.logTarget.scrollTop = this.logTarget.scrollHeight
      this.scrolled()
    })
  }

  disconnect() {
    cancelAnimationFrame(this.frame)
  }

  scrolled() {
    const log = this.logTarget
    this.followLatest = log.scrollHeight - log.scrollTop - log.clientHeight < 80
    this.latestTarget.hidden = this.followLatest
  }

  jump() {
    this.logTarget.scrollTo({ top: this.logTarget.scrollHeight, behavior: "auto" })
    this.scrolled()
  }

  imageLoaded() {
    if (this.followLatest) this.logTarget.scrollTop = this.logTarget.scrollHeight
  }
}
