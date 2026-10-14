# QR chuyển khoản đại lý

Giai đoạn hiện tại: thử trên admin. `payment_qr_telegram_enabled` mặc định **tắt**;
không bật tự động trong migration hoặc khi nhập ngân hàng đại lý.

## Thử trên admin

1. Cài đặt → Đại lý → Sửa: chọn ngân hàng, nhập số tài khoản và chủ tài khoản.
   Bật **Chuẩn bị yêu cầu QR sau duyệt** cho các bill duyệt từ thời điểm đó.
2. Bill đã duyệt → **Chuẩn bị yêu cầu xác nhận** (cũng dùng cho bill cũ).
3. Kiểm tra người nhận, HKD, mã và số tiền đại lý nhận sau phí. Có thể sửa số tiền
   chuyển rồi **Xác nhận & tạo QR**, hoặc hủy yêu cầu.
4. Quét thử bằng ứng dụng ngân hàng và đối chiếu người nhận / số tiền / nội dung.
   Không cần thực hiện chuyển tiền để kiểm tra.

Có thể dùng **Tải ảnh QR nhận tiền** trong form đại lý để điền sẵn các trường:
ngân hàng và số tài khoản đọc từ QR VietQR đã kiểm tra CRC; tên lấy từ QR nếu có,
hoặc AI đọc phần tên / số tài khoản in trên ảnh bằng cấu hình vision hiện có.
Tên đọc trên ảnh chỉ được điền khi đủ rõ và số tài khoản in trên ảnh khớp QR.
QR không có tên, ảnh mờ hoặc dịch vụ AI không khả dụng thì vẫn điền ngân hàng /
số tài khoản và yêu cầu bổ sung tên. Đây không phải xác minh chủ tài khoản với
ngân hàng. Kiểm tra lại rồi **Lưu**; đọc QR không tự lưu đại lý hoặc bật gửi nhóm.
Ảnh chỉ phục vụ lần đọc, không đính kèm vào bill hay lưu vào kho ảnh giao dịch.
Số tiền / nội dung có sẵn trên QR tải lên không được dùng cho bill sau này.

Số tiền mặc định là `dealer_amount_vnd`. Sửa số tiền QR không sửa số tiền bill,
phí, lợi nhuận hoặc workbook. Mã lấy từ `MerchantDealer.transfer_code` của đúng
HKD / đại lý / TID; không đoán mã theo tên đại lý. Thiếu hoặc nhiều mã không phân
biệt được thì chặn tạo QR và hiển thị lý do.

Yêu cầu lưu ảnh chụp thông tin người nhận và bill tại thời điểm chuẩn bị. Đổi tài
khoản, mã, tiền bill, thời điểm duyệt hoặc chuyển bill sang tạm giữ sẽ làm QR cũ
không còn tải được. **Làm mới yêu cầu** hủy xác nhận cũ và đổi token; lịch sử vẫn
ở nhật ký kiểm toán. QR đã tải / gửi ra ngoài không thể thu hồi khỏi thiết bị người
dùng, cần thông báo người nhận khi thay đổi.

## Bật Telegram sau giai đoạn thử

Chỉ thực hiện khi chủ ứng dụng quyết định bật gửi nhóm:

1. BotFather → bot đang kết nối → cấu hình **Main Mini App** URL
   `https://admin.hellosmc.com/telegram/payment-qr` (HTTPS).
2. Cài đặt → QR chuyển khoản: nhập username bot, không có `@`.
3. Cài đặt → Nhóm Telegram → Sửa: nhập Telegram **user ID số** của người được
   xác nhận / sửa tiền đi. Không dùng username; để trống thì không gửi và không
   ai xác nhận được. Chỉ nhóm đang bật hoạt động được nhận yêu cầu.
4. Bật **Gửi yêu cầu và QR vào nhóm Telegram**. Nếu dùng webhook, cập nhật
   webhook trong thẻ kết nối để Telegram nhận thêm `callback_query`; polling
   tự dùng danh sách update mới.

Bill duyệt mới sẽ nhận tin xác nhận trong nhóm nguồn, trong đúng topic / reply
bill. Tin có **Đúng — Tạo QR**, **Sửa số tiền** (mở Mini App), **Hủy**. Mini App
cho nhập số tiền đúng và submit. Xác nhận xong bot gửi PNG QR vào nhóm nguồn.
Bật cờ không tự gửi toàn bộ yêu cầu cũ; dùng **Làm mới yêu cầu** trên từng bill
muốn thử để tránh gửi hàng loạt ngoài ý muốn.

Mini App chỉ nhận Telegram initData đã kiểm tra HMAC và hạn một giờ; yêu cầu lấy
từ `start_param` có chữ ký. Backend kiểm tra user ID theo nhóm gốc và trạng thái
bill. Không dùng `initDataUnsafe`, tên người dùng hoặc chat ID do client gửi để
cấp quyền. Callback phải thuộc tin xác nhận gốc. Bấm lặp lại không tạo quyết
định / gửi QR lần hai.

Gửi Telegram có outbox claim trước network; timeout hoặc tiến trình chết sau
claim không tự gửi lại vì Telegram không hỗ trợ khóa idempotency cho sendPhoto.
Kiểm tra nhóm và trạng thái `summary_delivery` / `qr_delivery` trước khi làm mới.
`uncertain` có thông báo trên admin; `sending` kéo dài cần kiểm tra worker/log,
không reset và gửi lại khi chưa biết kết quả lần gửi trước.

## Kỹ thuật và nguồn chuẩn

QR sinh ngay trong app theo NAPAS VietQR bank-account transfer, mã dịch vụ
`QRIBFTTA`, VND `704`, CRC16/CCITT-FALSE, ảnh PNG từ RQRCode. Không gửi thông tin
ngân hàng tới dịch vụ tạo ảnh bên thứ ba. Tên chủ tài khoản là dữ liệu admin nhập
để đối chiếu, không phải kết quả xác minh chủ tài khoản của ngân hàng.

- VietQR: https://www.vietqr.io/qr-dong
- Danh mục ngân hàng: https://www.vietqr.io/api-bank
- Ví dụ đặc tả NAPAS: https://github.com/subiz/vietqr
- Telegram initData: https://core.telegram.org/bots/webapps#validating-data-received-via-the-mini-app
- Main Mini App: https://core.telegram.org/bots/webapps#direct-link-mini-apps
- Telegram Web iframe: https://core.telegram.org/api/web-events

Danh mục `config/vietqr_banks.json` là snapshot API ngân hàng ngày 14/10/2026,
gồm đủ 75 ngân hàng / đơn vị API trả về. Không lọc ngân hàng nhận theo
`transferSupported`: trường này mô tả app ngân hàng có hỗ trợ quét QR để chuyển
tiền hay không, theo tài liệu API VietQR. Cập nhật từ API chính thức khi thêm ngân
hàng; không gọi API đó trong mỗi lần render / xử lý bill. Chạy migration trước
khi khởi động web và worker với code mới. Không cần API key VietQR.
