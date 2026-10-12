# Spec kỹ thuật: Đơn giản hoá cấu hình cho người dùng không chuyên kỹ thuật

| | |
|---|---|
| Trạng thái | Đã implement trên branch `feature/simplify-settings` (12/10/2026), chưa chạy suite |
| Phạm vi | Trang Cài đặt (`AppSetting`, `SettingsForm`, `AppConfig`), form Người đi tiền, form HKD → đại lý, form Nhóm Telegram, form Loại thẻ |
| Không đổi | Cách tính phí, OCR, ghi Google Sheet, giá trị đang chạy trên prod |

---

## 1. Bối cảnh và yêu cầu

Người dùng (12/10/2026): *"App đang setting config quá nhiều, có thể hardcode hay làm một cách nào đó để tự động hơn được không? Client không phải dân tech, không biết config mấy cái này."*

Yêu cầu:
1. Trang Cài đặt chỉ còn những gì khách hiểu và cần quyết.
2. Thông số kỹ thuật: hardcode, dev vẫn chỉnh được mà không sửa code.
3. Form nào bắt khách gõ thứ khách không biết (Telegram ID, tên ô trên Google Sheet…) thì tự điền.
4. **Không đổi hành vi prod** khi deploy.

---

## 2. Hiện trạng và root cause

| Chỗ | Khách phải tự nhập/hiểu |
|---|---|
| Cài đặt (24 mục, 6 nhóm) | Nhà cung cấp OCR, 4 tên model, bật/tắt + cách kiểm tra OCR, thời gian chờ, số lần OCR, 2 ngưỡng tin cậy, 3 thông số làm rõ ảnh, ngưỡng gợi ý HKD, phút kiểm tra trùng, tuổi bill, thời gian chờ album, dung lượng ảnh, email người gửi, Spreadsheet ID, 2 công tắc Telegram |
| Người đi tiền | Telegram **user ID** (khách không có cách xem), cột Excel |
| HKD → đại lý | TID, "anchor" tab DS MB, tiêu đề cột DS MB, nhãn khối thu chi |
| Nhóm Telegram | Telegram chat ID (bot đã tự ghi) |
| Loại thẻ | key, thứ tự |

**Root cause:** mọi tham số được đưa lên giao diện "cho linh hoạt", không tách *quyết định nghiệp vụ* (của khách) khỏi *tinh chỉnh kỹ thuật* (của dev); các trường kỹ thuật không có giá trị tự sinh.

---

## 3. Giải pháp

### 3.1 Phân loại thông số

| Mục | Ai quyết | Xử lý |
|---|---|---|
| Tự động nhận nhóm Telegram mới, Bật đi tiền | Khách | **Giữ** trên trang Cài đặt |
| Token bot Telegram, đăng ký webhook | Khách (một lần) | Giữ (đã có) |
| 22 mục còn lại | Dev | **Bỏ khỏi giao diện** → `AppConfig` |

### 3.2 `AppConfig`: giá trị kỹ thuật

Thứ tự lấy giá trị mỗi thông số:

1. **Biến môi trường** trên Coolify (dev chỉnh, restart là áp dụng).
2. **Giá trị đã lưu trong bảng `app_settings`** từ khi còn trên trang Cài đặt (chỉ đọc). → Deploy **không đổi** hành vi prod, dù trước đó ai đã chỉnh gì.
3. **Mặc định trong code.**

| Thông số | Biến môi trường | Mặc định |
|---|---|---|
| Nhà cung cấp OCR | `OCR_PROVIDER` | `openai` |
| Model đọc bill | `OCR_PRIMARY_MODEL` | `gpt-6-luna` (giữ cách đọc `openai_vision_model` cũ) |
| Model kiểm tra lại | `OCR_VALIDATOR_MODEL` | `gpt-6.1-sol` |
| Bật kiểm tra lại | `OCR_VALIDATION_ENABLED` | `true` |
| Model Gemini | `GEMINI_VISION_MODEL` | `gemini-2.5-flash` |
| Ngưỡng tự duyệt | `OCR_AUTO_APPROVE_THRESHOLD` | `0.92` |
| Ngưỡng đọc được | `OCR_REVIEW_THRESHOLD` | `0.70` |
| Thời gian chờ OCR (giây) | `OCR_TIMEOUT_SECONDS` | `60` |
| Số lượt OCR / bill | `OCR_MAX_ATTEMPTS` | `3` (luôn kẹp 1–3) |
| Làm rõ ảnh | `OCR_IMAGE_ENHANCEMENT` | `validator` |
| Cạnh ngắn tối thiểu (px) | `OCR_ENHANCE_MIN_SHORT_SIDE` | `1000` |
| Ngưỡng ảnh mờ | `OCR_ENHANCE_BLUR_THRESHOLD` | `100` |
| Ngưỡng gợi ý HKD gần đúng | `MERCHANT_FUZZY_THRESHOLD` | `0.88` |
| Phút kiểm tra trùng | `DUPLICATE_WINDOW_MINUTES` | `10` |
| Tuổi tối đa của bill (ngày) | `MAX_RECEIPT_AGE_DAYS` | `45` |
| Chờ ảnh album (giây) | `ALBUM_COLLECT_WINDOW_SECONDS` | `15` |
| Dung lượng ảnh tối đa (MB) | `MAX_BILL_IMAGE_MB` | `20` |
| Email người gửi | `MAILER_SENDER` | `no-reply@hellosmc.com` |
| Spreadsheet Hello SMC | `HELLO_SMC_SPREADSHEET_ID` | (trống) — đã có từ trước |

`vision_validation_mode` chỉ có một giá trị (`risk_based`) → hằng số.

### 3.3 Trang Cài đặt mới

- Một khối "Vận hành" với 2 công tắc, mô tả bằng lời thường.
- Khối Telegram (token, webhook) và Kết nối dịch vụ giữ nguyên.
- Cảnh báo nổi bật khi thiếu API key OCR ("OCR chưa hoạt động — liên hệ kỹ thuật").
- Khối thu gọn **"Thông số kỹ thuật"** (chỉ admin thấy, chỉ đọc): tên, giá trị đang dùng, nguồn (biến môi trường / đã lưu trước đây / mặc định). Dev xem nhanh mà khách không phải đụng.

### 3.4 Form tự điền

| Form | Thay đổi |
|---|---|
| **Người đi tiền** | Ô Telegram ID có **gợi ý từ những người đã nhắn trong các nhóm** (60 ngày gần nhất, chưa gắn người đi tiền khác): gõ hoặc chọn "Lập (@laplap) · 12345". Lưu xong, username tự điền từ tin nhắn của người đó nếu để trống. **Cột Excel** để trống → tự lấy tên viết hoa (Lập → LẬP). |
| **HKD → đại lý** | Chỉ còn Đại lý + Máy (TID). Ba ô tên trên Google Sheet dời vào khối "Nâng cao" thu gọn; để trống thì tự điền: tiêu đề cột DS MB = `"<tên đại lý> (<tid>)"` (so khớp không phân biệt dấu cách), nhãn khối thu chi = tên đại lý, tên bảng DS MB = lấy từ dòng đại lý khác của **cùng HKD** (đã đúng với sheet). HKD chưa có dòng nào thì vẫn phải nhập (không đoán, vì đoán sai sẽ đẩy bill vào "Bill vô chủ"). |
| **Nhóm Telegram** | Chat ID chỉ hiển thị khi sửa (bot tự ghi). |
| **Loại thẻ** | Mã (key) để trống → tự sinh từ tên; thứ tự tự xếp cuối. |

---

## 4. Phương án đã cân nhắc

| | Phương án | Nhược | Chọn |
|---|---|---|---|
| A | Xoá hẳn mọi thông số, chỉ hằng số | Dev muốn chỉnh ngưỡng phải sửa code + deploy; có thể đổi hành vi prod khi deploy | Không |
| **B** | **Hằng số + biến môi trường + đọc giá trị đã lưu cũ** | Hai nơi để xem (đã có khối "Thông số kỹ thuật") | **Có** |
| C | Giữ trên giao diện nhưng ẩn sau vai trò "kỹ thuật" | Thêm vai trò, khách vẫn có thể bấm nhầm | Không |
| D | Tự sinh tên bảng DS MB từ tên HKD | Đoán sai → bill âm thầm vào "Bill vô chủ" | Không (chỉ lấy từ dòng cùng HKD) |

---

## 5. Test case

| ID | Tình huống | Kỳ vọng | File |
|---|---|---|---|
| C1 | Không ENV, không giá trị lưu | Mặc định §3.2 | `spec/lib/app_config_spec.rb` |
| C2 | Có giá trị lưu cũ (`ocr_auto_approve_threshold` = 0.95) | 0.95 | idem |
| C3 | ENV `OCR_AUTO_APPROVE_THRESHOLD=0.9` + giá trị lưu 0.95 | 0.9 | idem |
| C4 | `openai_vision_model` cũ đã lưu, chưa có `primary_vision_model` | Dùng model cũ | idem |
| C5 | `OCR_MAX_ATTEMPTS=10` | 3 | idem |
| C6 | `MAX_BILL_IMAGE_MB=5` | 5 MB | idem |
| S1 | Trang Cài đặt | Chỉ 2 công tắc + Telegram + dịch vụ; không còn ô ngưỡng/model | `spec/requests/settings_spec.rb` |
| S2 | Lưu công tắc Bật đi tiền | Lưu + audit | `spec/models/settings_form_spec.rb` |
| S3 | Gửi kèm key đã bỏ (`ocr_auto_approve_threshold`) | Bị bỏ qua, không lưu | idem |
| S4 | Khối Thông số kỹ thuật | Hiện giá trị + nguồn, chỉ đọc (trang Cài đặt vốn chỉ admin vào được) | `spec/requests/settings_spec.rb` |
| R1 | Người đi tiền: gợi ý người đã nhắn | Datalist có "Lập (@laplap)", không có người đã gắn | `spec/requests/admin/remitters_spec.rb` |
| R2 | Lưu với Telegram ID, username trống | Username tự điền từ tin nhắn | idem |
| R3 | Cột Excel trống | `LẬP` | `spec/models/remitter_spec.rb` |
| M1 | Thêm đại lý cho HKD đã có dòng | Tên bảng lấy từ dòng cũ; tiêu đề `"Sơn (tid2)"`; nhãn `"Sơn"` | `spec/models/merchant_dealer_spec.rb` |
| M2 | HKD chưa có dòng nào, để trống tên bảng | Lỗi "cần nhập" | idem |
| M3 | Đã nhập tay | Giữ nguyên | idem |
| K1 | Loại thẻ không nhập mã | Mã sinh từ tên, thứ tự cuối | `spec/models/card_type_spec.rb` |

---

## 6. Rủi ro

| # | Rủi ro | Mức | Giảm thiểu |
|---|---|---|---|
| 1 | Dev quên rằng giá trị cũ trong `app_settings` vẫn đang được dùng | Thấp | Khối "Thông số kỹ thuật" ghi nguồn; ENV luôn thắng |
| 2 | ENV sai định dạng (`OCR_AUTO_APPROVE_THRESHOLD=abc`) | Thấp | Đọc lỗi → dùng mặc định + log cảnh báo |
| 3 | Tiêu đề cột tự sinh không khớp sheet (đại lý đặt tên khác) | Thấp | Chỉ tự điền khi trống; sửa trong "Nâng cao"; sai thì bill vào "Bill vô chủ" kèm lý do `ds_header` như hiện tại |
| 4 | Gợi ý Telegram ID lộ danh sách người nhắn | Thấp | Chỉ người có quyền quản lý người đi tiền thấy |

---

## 7. Triển khai và rollback

Deploy bình thường, không migration. Muốn đổi thông số: Coolify → Environment Variables → thêm biến §3.2 → restart.

Rollback: revert branch; các giá trị trong `app_settings` vẫn nguyên.

---

## 8. File thay đổi

`lib/app_config.rb`, `app/models/app_setting.rb`, `app/models/settings_form.rb`, `app/controllers/admin/settings_controller.rb`, `app/views/admin/settings/show.html.erb`, `app/models/{remitter,merchant_dealer,card_type}.rb`, `app/controllers/admin/remitters_controller.rb`, `app/views/admin/{remitters,merchants,telegram_chats,card_types}/_form.html.erb`, `config/locales/vi.yml`, specs §5.
