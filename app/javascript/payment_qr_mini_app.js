const app = window.Telegram?.WebApp
const message = document.getElementById("payment-message")
const form = document.getElementById("payment-form")
const amount = document.getElementById("payment-amount")
const confirm = document.getElementById("payment-confirm")
const cancel = document.getElementById("payment-cancel")
let state
let busy = false
const money = value => `${new Intl.NumberFormat("vi-VN").format(value)} ₫`

function notice(text, error = false) {
  message.textContent = text
  message.className = `alert alert-${error ? "danger" : "info"}`
}

async function api(action, body = {}) {
  const response = await fetch(`/telegram/payment-qr/${action}`, {
    method: "POST", credentials: "omit", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...body, init_data: app?.initData || "" })
  })
  const data = await response.json()
  if (!response.ok) throw new Error(data.error || "Không thể xử lý. Hãy thử tải lại.")
  return data
}

function render(data) {
  state = data
  document.getElementById("payment-details").hidden = false
  const summary = document.getElementById("payment-summary")
  summary.replaceChildren()
  for (const [label, value] of [
    ["Bill", `#${data.id}`], ["Đại lý", data.dealer_name], ["HKD", data.merchant_name],
    ["Ngân hàng", data.bank_name], ["Số tài khoản", data.account_number],
    ["Chủ tài khoản", data.account_name], ["Nội dung", data.transfer_code],
    ["Tiền theo bill", money(data.dealer_amount_vnd)]
  ]) {
    const row = document.createElement("div")
    row.className = "mb-2 text-break"
    const title = document.createElement("span")
    title.className = "text-secondary"
    title.textContent = `${label}: `
    row.append(title, document.createTextNode(value || "—"))
    summary.append(row)
  }
  form.hidden = data.status !== "pending"
  amount.value = data.dealer_amount_vnd
  if (data.status === "confirmed") {
    document.getElementById("payment-result").hidden = false
    const image = document.createElement("img")
    image.src = `data:image/png;base64,${data.qr_png}`
    image.width = image.height = 480
    image.className = "img-fluid"
    image.alt = "QR chuyển khoản theo số tiền đã xác nhận"
    document.getElementById("payment-image").replaceChildren(image)
    document.getElementById("payment-confirmed-amount").textContent = money(data.transfer_amount_vnd)
    notice("Đã xác nhận. QR sẽ được gửi vào nhóm gốc của bill.")
  } else if (data.status === "cancelled") {
    notice("Yêu cầu đã hủy.")
  } else {
    notice("Kiểm tra người nhận và số tiền trước khi tạo QR.")
  }
}

async function decide(decision) {
  if (busy || !state) return
  busy = true
  confirm.disabled = cancel.disabled = true
  notice("Đang lưu quyết định…")
  try {
    render(await api("decide", { decision, amount: amount.value, version: state.version }))
  } catch (error) {
    notice(error.message, true)
  } finally {
    busy = false
    confirm.disabled = cancel.disabled = false
  }
}

form.addEventListener("submit", event => { event.preventDefault(); decide("confirm") })
cancel.addEventListener("click", () => decide("cancel"))
amount.addEventListener("input", () => {
  confirm.textContent = amount.value === String(state?.dealer_amount_vnd) ? "Đúng — Tạo QR" : "Xác nhận số tiền đã sửa & tạo QR"
})
if (app?.initData) {
  const applyTheme = () => { document.documentElement.dataset.bsTheme = app.colorScheme === "dark" ? "dark" : "light" }
  applyTheme()
  app.onEvent("themeChanged", applyTheme)
  app.ready()
  app.expand()
  api("context").then(render).catch(error => notice(error.message, true))
} else {
  notice("Mở từ nút Sửa số tiền trong nhóm Telegram để xác thực.", true)
}
