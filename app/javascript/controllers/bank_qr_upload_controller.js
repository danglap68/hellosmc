import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["file", "status", "preview", "bank", "account", "holder"]
  static values = { url: String }

  connect() {
    this.sequence = 0
    this.form = this.element.closest("form")
    this.guardSubmit = event => {
      if (this.busy) event.preventDefault()
    }
    this.form.addEventListener("submit", this.guardSubmit)
  }

  disconnect() {
    this.cancel()
    this.form.removeEventListener("submit", this.guardSubmit)
    this.clearPreview()
  }

  choose() {
    this.fileTarget.value = ""
    this.fileTarget.click()
  }

  async read() {
    this.cancel()
    this.clearPreview()
    const sequence = this.sequence
    const file = this.fileTarget.files[0]
    if (!file) return
    if (!['image/png', 'image/jpeg', 'image/webp'].includes(file.type) || file.size > 10 * 1024 * 1024) {
      return this.notice("Dùng ảnh QR PNG, JPG hoặc WebP, tối đa 10 MB.", "danger")
    }

    this.setBusy(true)
    this.notice("Đang đọc ảnh QR…")
    try {
      const image = await this.loadImage(file)
      if (sequence !== this.sequence) return
      if (image.naturalWidth * image.naturalHeight > 24000000) throw new Error("Ảnh quá lớn. Hãy chụp hoặc cắt riêng mã QR, tối đa 24 megapixel.")
      await import("jsqr")
      if (sequence !== this.sequence) return
      // Paint the loading state before decoding a potentially large screenshot.
      await new Promise(resolve => requestAnimationFrame(resolve))
      const canvas = this.canvas(image, 1600)
      let payload = this.decode(canvas)
      if (!payload) payload = this.decode(this.canvas(image, 1000))
      if (!payload) throw new Error("Chưa tìm thấy mã QR. Hãy dùng ảnh gốc rõ nét hoặc cắt riêng mã QR.")
      this.notice("Đã đọc mã QR. Đang lấy thông tin người nhận…")
      const blob = await new Promise(resolve => canvas.toBlob(resolve, "image/jpeg", 0.9))
      if (sequence !== this.sequence) return
      if (!blob) throw new Error("Không đọc được ảnh này. Hãy dùng ảnh PNG hoặc JPG khác.")
      const body = new FormData()
      body.set("qr_payload", payload)
      body.set("image", blob, "qr-recipient.jpg")
      this.request = new AbortController()
      const timeout = setTimeout(() => this.request?.abort(), 40000)
      let response
      try {
        response = await fetch(this.urlValue, {
          method: "POST", credentials: "same-origin", body, signal: this.request.signal,
          headers: { "Accept": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" }
        })
      } finally { clearTimeout(timeout) }
      if (sequence !== this.sequence) return
      if (!response.headers.get("Content-Type")?.includes("application/json")) throw new Error("Phiên đăng nhập đã hết hạn. Tải lại trang rồi thử lại.")
      const data = await response.json()
      if (sequence !== this.sequence) return
      if (!response.ok) throw new Error(data.error || "Không đọc được thông tin từ QR. Hãy thử ảnh khác.")

      this.bankTarget.value = data.bank_bin
      this.accountTarget.value = data.bank_account_number
      // Never leave the previous account holder attached to a new account.
      this.holderTarget.value = data.bank_account_name || ""
      for (const field of [this.bankTarget, this.accountTarget, this.holderTarget]) {
        field.dispatchEvent(new Event("input", { bubbles: true }))
        field.dispatchEvent(new Event("change", { bubbles: true }))
      }
      this.previewUrl = URL.createObjectURL(file)
      const preview = new Image(112, 112)
      preview.src = this.previewUrl
      preview.alt = "Ảnh QR nhận tiền vừa chọn"
      preview.className = "img-thumbnail object-fit-contain"
      this.previewTarget.replaceChildren(preview)
      this.previewTarget.hidden = false
      this.notice(data.message, data.bank_account_name ? "success" : "warning")
    } catch (error) {
      if (sequence !== this.sequence) return
      const message = error.name === "AbortError" ? "Đọc ảnh quá lâu. Thử lại hoặc nhập thông tin bên dưới." :
        error instanceof TypeError || error instanceof SyntaxError ? "Không kết nối được máy chủ để đọc QR. Hãy thử lại." :
          error.message || "Không đọc được ảnh QR. Hãy thử lại."
      this.notice(message, "danger")
    } finally {
      if (sequence === this.sequence) this.setBusy(false)
    }
  }

  cancel() {
    this.sequence += 1
    this.request?.abort()
    this.setBusy(false)
  }

  setBusy(busy) {
    if (busy) {
      this.disabledFields = new Map([this.bankTarget, this.accountTarget, this.holderTarget, ...this.form.querySelectorAll('[type="submit"]')].map(field => [field, field.disabled]))
      for (const field of this.disabledFields.keys()) field.disabled = true
    } else {
      for (const [field, disabled] of this.disabledFields || []) field.disabled = disabled
      this.disabledFields = null
    }
    this.busy = busy
    this.element.setAttribute("aria-busy", String(busy))
  }

  clearPreview() {
    if (this.previewUrl) URL.revokeObjectURL(this.previewUrl)
    this.previewUrl = null
    this.previewTarget.replaceChildren()
    this.previewTarget.hidden = true
  }

  notice(text, tone = "secondary") {
    this.statusTarget.textContent = text
    this.statusTarget.className = `small mb-0 text-${tone}`
  }

  loadImage(file) {
    return new Promise((resolve, reject) => {
      const url = URL.createObjectURL(file)
      const image = new Image()
      image.onload = () => { URL.revokeObjectURL(url); resolve(image) }
      image.onerror = () => { URL.revokeObjectURL(url); reject(new Error("Ảnh không đọc được. Hãy chọn ảnh PNG hoặc JPG khác.")) }
      image.src = url
    })
  }

  canvas(image, maxSize) {
    const scale = Math.min(1, maxSize / Math.max(image.naturalWidth, image.naturalHeight))
    const canvas = document.createElement("canvas")
    canvas.width = Math.round(image.naturalWidth * scale)
    canvas.height = Math.round(image.naturalHeight * scale)
    const context = canvas.getContext("2d", { willReadFrequently: true })
    context.fillStyle = "white"
    context.fillRect(0, 0, canvas.width, canvas.height)
    context.drawImage(image, 0, 0, canvas.width, canvas.height)
    return canvas
  }

  decode(canvas) {
    const { width, height } = canvas
    const pixels = canvas.getContext("2d").getImageData(0, 0, width, height)
    const code = window.jsQR(pixels.data, width, height, { inversionAttempts: "attemptBoth" })
    const found = new Set(code ? [code.data] : [])
    // Detect an additional QR instead of choosing a recipient arbitrarily.
    if (code) {
      const corners = [code.location.topLeftCorner, code.location.topRightCorner, code.location.bottomLeftCorner, code.location.bottomRightCorner]
      const left = Math.max(0, Math.floor(Math.min(...corners.map(point => point.x))) - 4)
      const right = Math.min(width, Math.ceil(Math.max(...corners.map(point => point.x))) + 4)
      const top = Math.max(0, Math.floor(Math.min(...corners.map(point => point.y))) - 4)
      const bottom = Math.min(height, Math.ceil(Math.max(...corners.map(point => point.y))) + 4)
      for (let y = top; y < bottom; y++) pixels.data.fill(255, (y * width + left) * 4, (y * width + right) * 4)
      const other = window.jsQR(pixels.data, width, height, { inversionAttempts: "attemptBoth" })
      if (other) found.add(other.data)
    }
    // Two equally sized codes can confuse the full-image locator. Scan
    // separate halves as well, without trusting whichever code it finds first.
    if (!code || width > height * 1.3 || height > width * 1.3) {
      const halfWidth = Math.floor(width / 2)
      const halfHeight = Math.floor(height / 2)
      const regions = width > height ? [[0, 0, halfWidth, height], [halfWidth, 0, width - halfWidth, height]] :
        [[0, 0, width, halfHeight], [0, halfHeight, width, height - halfHeight]]
      for (const [x, y, regionWidth, regionHeight] of regions) {
        const region = canvas.getContext("2d").getImageData(x, y, regionWidth, regionHeight)
        const result = window.jsQR(region.data, regionWidth, regionHeight, { inversionAttempts: "attemptBoth" })
        if (result) found.add(result.data)
      }
    }
    if (found.size > 1) throw new Error("Ảnh có nhiều mã QR khác nhau. Hãy cắt hoặc chụp riêng một mã nhận tiền.")
    return found.values().next().value || null
  }
}
