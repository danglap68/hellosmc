import { Controller } from "@hotwired/stimulus"

// Open a conversation on the newest line, the way a chat app does.
export default class extends Controller {
  connect() {
    this.element.scrollTop = this.element.scrollHeight
  }
}
