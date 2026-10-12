# Spec kỹ thuật: Thu thập đầy đủ tin nhắn nhóm và trang "Tin nhắn"

| | |
|---|---|
| Trạng thái | **Bước 0 (mục 3.8) đã implement** (13/10/2026); các bước còn lại đề xuất, chờ duyệt. Branch: `feature/collect-all-telegram-messages` |
| Phạm vi | Bill tự bỏ qua (SmartPOS, HKD "Bỏ qua bill") nay lưu thành bản ghi có tag (mục 3.8); `Telegram::UpdateReceiver`, `Telegram::MessageParser`, `Webhooks::TelegramController`, bảng `telegram_messages`, bảng mới `telegram_updates`, trang Admin "Tin nhắn", task `hellosmc:purge_transaction_data` |
| Không đổi | OCR, tạo giao dịch, đi tiền, ghi Google Sheet, những gì được tải và OCR (chỉ ảnh của nhóm đang bật) |

---

## 1. Bối cảnh và yêu cầu

Người dùng (13/10/2026): *"Cho hệ thống thu thập full tin nhắn để dễ đối soát, sau này làm tiếp phần quản lý tin nhắn đa kênh về app này. Làm thêm phần Message để hiển thị tin nhắn các group, để xem đang thu thập tin nhắn đủ không."*

Yêu cầu:
1. Lưu **mọi** tin nhắn của mọi nhóm bot ở trong (text, ảnh, file, voice, reply, forward, tin được sửa), không chỉ tin liên quan tới bill.
2. Trang xem tin nhắn theo nhóm, có bộ lọc, và cho biết **thu thập có đủ không**.
3. Thiết kế để sau này thêm kênh khác (Zalo…) mà không phải làm lại. Chưa làm kênh khác trong lần này.
4. Không đổi cách xử lý bill hiện tại.
5. (Bổ sung 13/10/2026) Bill tự bỏ qua vì tính giá khác (máy **SmartPOS**, HKD **Thiên Kim** hay mọi HKD bật "Bỏ qua bill") **không bị bỏ đi mà được gắn tag**: vẫn theo dõi được trong danh sách giao dịch, mặc định ẩn bằng bộ lọc tag, khi cần đối soát thì lấy ra hoặc chạy backfill được.

---

## 2. Hiện trạng và root cause

`UpdateReceiver` đã lưu một `TelegramMessage` (kèm toàn bộ update trong `raw_payload`) cho mọi tin của nhóm **đang bật**, kể cả text. Dữ liệu thiếu vì các chỗ sau:

| # | Chỗ thiếu | Nguyên nhân trong code | Hậu quả |
|---|---|---|---|
| G1 | Tin không phải ảnh của nhóm **đang tắt** bị bỏ | `update_receiver.rb`: `return result(:ignored_inactive_chat) if !chat.active? && !parsed.image?` | Không có gì để đối soát với nhóm đó |
| G2 | Tin được sửa mà bản gốc chưa lưu bị bỏ | `handle_edit` trả `:ignored_edit_unknown_message` | Mất tin |
| G3 | Tin không phải text/ảnh (voice, video, sticker, file, vị trí, danh bạ, tin hệ thống) không có "loại"; `message_text` rỗng | `MessageParser` chỉ đọc `text`/`caption` và ảnh | Trang hiển thị "—", không biết đó là gì |
| G4 | Reply, forward chỉ nằm trong `raw_payload` | Không có cột | Không hiển thị được "trả lời tin …" |
| G5 | Webhook chỉ xếp job vào Sidekiq rồi trả 200; nếu Redis/Sidekiq mất job thì update mất, Telegram không gửi lại | `Webhooks::TelegramController#create` | Mất tin âm thầm |
| G6 | Không có chỗ nào cho biết nhóm nào đang thiếu tin | — | Không kiểm chứng được "đủ chưa" |
| G8 | Bill SmartPOS / HKD "Bỏ qua bill" bị bỏ hẳn, không có bản ghi (`Transactions::Builder#other_fee_calculation?` chỉ ghi `skipped_reason` vào metadata ảnh) | Không tìm lại được trong "Giao dịch", không đối soát, không backfill được ngoài việc chạy lại OCR |
| G7 | `hellosmc:purge_transaction_data` xoá luôn `telegram_messages` | `PURGE_DATA_TABLES` | Dọn dữ liệu giao dịch làm mất bằng chứng đối soát |

### Giới hạn của Telegram Bot API (không sửa được bằng code, phải nói rõ với người dùng)

| Giới hạn | Hệ quả | Cách xử lý |
|---|---|---|
| **Privacy mode**: bot không phải admin nhóm và BotFather `/setprivacy` đang *Enabled* thì chỉ nhận lệnh và reply, không nhận mọi tin | Thiếu tin; đây là nguyên nhân khả dĩ nhất | `getMe` trả `can_read_all_group_messages`; trang cảnh báo nếu `false` |
| Tin bị **xoá** không được gửi cho bot | Không biết tin nào đã bị xoá | Ghi chú trên trang; chỉ phát hiện gián tiếp qua khoảng trống `message_id` |
| Không lấy được **lịch sử** trước khi bot vào nhóm | Chỉ thu từ lúc bot vào | Tuỳ chọn sau: import file export JSON của Telegram Desktop (ngoài phạm vi) |
| Tin của **bot khác** không được gửi cho bot | Thiếu tin của bot | Ghi chú trên trang |

---

## 3. Giải pháp

### 3.1 Dữ liệu

Migration `add_message_fields_to_telegram_messages` (đảo được):

| Cột | Kiểu | Ý nghĩa |
|---|---|---|
| `kind` | string, not null, default `"text"` | `text photo document video voice audio sticker location contact service other` |
| `reply_to_message_id` | bigint, null | `message_id` của tin được trả lời (cùng nhóm) |
| `forwarded_from` | string, null | Tên người/kênh gốc nếu là tin chuyển tiếp |
| `edited_at` | datetime, null | Lần sửa gần nhất |

Backfill `kind` cho dữ liệu cũ bằng một câu SQL đọc `raw_payload` (có `photo` → `photo`, `document` → `document`, có `text` → `text`, có `new_chat_members`/`left_chat_member`/`pinned_message`… → `service`, còn lại `other`). Không backfill `reply_to_message_id`, `forwarded_from`, `edited_at` (chỉ áp dụng cho tin mới).

Index:
- `(telegram_chat_id, sent_at DESC)`: danh sách theo nhóm.
- `(sent_at DESC)`: danh sách mọi nhóm.
- GIN `pg_trgm` trên `message_text` để tìm từ khoá. Nếu DB không cho tạo extension thì dùng `ILIKE` không index (chấp nhận được ở quy mô hiện tại); migration kiểm tra trước.

Bảng mới `telegram_updates` (hộp thư đến cho webhook, xem 3.3):

| Cột | Kiểu |
|---|---|
| `update_id` | bigint, unique, not null |
| `payload` | jsonb, not null |
| `status` | string, `received` / `processed` / `failed`, default `received` |
| `attempts` | integer, default 0 |
| `received_at`, `processed_at` | datetime |

Chưa thêm cột `channel`. Khi làm kênh thứ hai sẽ thêm `channel` (default `telegram`) và `external_id`; giao diện mới dùng chữ trung tính ("Tin nhắn", "Nguồn") để không phải đổi tên.

### 3.2 Thu thập

| Gap | Thay đổi |
|---|---|
| G1 | Nhóm tắt: **lưu mọi tin** (text và media) với `processing_status = "ignored"`. Ảnh của nhóm tắt vẫn chỉ lưu, không tải, không OCR (hành vi hiện tại). Nhóm mới tự tạo (bất kể bật hay tắt) cũng lưu. |
| G2 | Sửa tin chưa có bản gốc: tạo tin từ payload đã sửa, `edited_at` = thời điểm sửa, ghi audit `telegram_message.created_from_edit`. |
| G3, G4 | `MessageParser::Parsed` thêm `kind`, `reply_to_message_id`, `forwarded_from`; `persist_message` lưu. Tin hệ thống (thêm/xoá thành viên…) có `message_id` nên được lưu với `kind = "service"` và được tính là "đã nhận" khi kiểm tra khoảng trống. |
| Sửa tin đã có | Giữ hành vi hiện tại (thay `message_text`, lịch sử trong `raw_payload["edits"]`), thêm `edited_at`. |

Tính idempotent giữ nguyên: `(telegram_chat_id, telegram_message_id)` unique.

### 3.3 Webhook bền (G5)

Luồng mới trong `Webhooks::TelegramController#create`:
1. Kiểm tra secret (như cũ).
2. `INSERT INTO telegram_updates ... ON CONFLICT (update_id) DO NOTHING` (một câu lệnh, nhanh).
3. `ProcessTelegramUpdateJob.perform_later(telegram_update.id)`; trả `200`.
4. Job đọc payload từ DB, gọi `UpdateReceiver`, đặt `status = processed`; lỗi → `failed`, `attempts += 1`, giữ retry như cũ.
5. Job quét định kỳ (`RetryStuckTelegramUpdatesJob`, mỗi 5 phút): xếp lại các dòng `received`/`failed` quá 5 phút và `attempts < 5`. Dùng cơ chế job định kỳ đang có của dự án (xác nhận khi implement).
6. Dọn: xoá dòng `processed` cũ hơn 14 ngày (payload đầy đủ đã nằm ở `telegram_messages.raw_payload`).

Nếu insert vào DB lỗi thì trả `500` để Telegram tự gửi lại (Telegram retry khi không nhận được 2xx).

Poller (chạy local) giữ nguyên, đi thẳng vào `UpdateReceiver`.

### 3.4 Trang "Tin nhắn" (`/admin/messages`)

Menu mới "Tin nhắn", cạnh "Nhóm Telegram".

**Danh sách** (pagy, 50 dòng/trang, mới nhất trước; truy vấn **không** chọn `raw_payload`):

| Cột | Nội dung |
|---|---|
| Thời gian | `sent_at`; badge "đã sửa" nếu `edited_at` |
| Nhóm | Tên nhóm, bấm để lọc |
| Người gửi | `sender_name` (@username) |
| Nội dung | Text; tin không text hiện `[Ảnh]`, `[Voice]`, `[File]`… theo `kind`; dòng phụ "↩ trả lời tin …" / "chuyển tiếp từ …" |
| Kết quả | Link tới giao dịch, chuyển tiền hoặc album tạo từ tin (nếu có); trạng thái xử lý |

**Bộ lọc** (query params, giữ khi chuyển trang): `chat_id`, `sender` (tên hoặc username), `from`/`to` (ngày, giờ Asia/Ho_Chi_Minh), `kind`, `q` (từ khoá), `only_images`, `unprocessed`.

**Chi tiết tin**: `GET /admin/messages/:id` — toàn văn, lịch sử sửa, bản ghi liên quan, và (chỉ admin) JSON thô `raw_payload`.

**Khối "Sức khoẻ thu thập"** (đầu trang, mỗi nhóm một dòng):

| Chỉ số | Cách tính |
|---|---|
| Tin cuối nhận lúc | `MAX(sent_at)` |
| Hôm nay / 7 ngày | `COUNT` theo `sent_at` |
| **Tin có thể bị thiếu** | Trong 7 ngày gần nhất, nếu có ≥ 2 tin: `(MAX(telegram_message_id) − MIN(telegram_message_id) + 1) − COUNT(*)`. Id tin trong một nhóm tăng liên tục, nên khoảng trống là tin ta không nhận được. **Chỉ là gợi ý**: tin bị xoá và tin của bot khác cũng tạo khoảng trống |
| Cảnh báo "im lặng" | Nhóm đang bật không có tin nào trong 24 giờ |
| Cảnh báo privacy mode | `getMe.can_read_all_group_messages == false` → "Bot chưa đọc được mọi tin nhắn nhóm: tắt Privacy mode trong BotFather hoặc đặt bot làm admin nhóm." Kết quả `getMe` cache 1 giờ; lỗi gọi API thì không hiện cảnh báo |

Bấm vào số "có thể bị thiếu" lọc danh sách theo nhóm và hiển thị các `message_id` còn thiếu (tối đa 50 đầu tiên) để đối chiếu với app Telegram.

Trang Nhóm Telegram giữ thẻ "Tin nhắn gần đây" và thêm link "Xem tất cả" (lọc theo nhóm).

### 3.5 Phân quyền và dữ liệu cá nhân

- Tài nguyên mới `:messages` trong `Permissions::MATRIX`: `admin` toàn quyền, `operator` đọc, `viewer` không thấy (đề xuất; xem mục 9).
- Tin nhắn nhóm có thể chứa thông tin cá nhân. Chỉ người đăng nhập có quyền xem; JSON thô chỉ admin; không log nội dung tin vào log ứng dụng (StructuredLog chỉ ghi id).
- Token bot không nằm trong payload.

### 3.6 Lệnh xoá dữ liệu (G7)

`hellosmc:purge_transaction_data` bỏ `telegram_messages` khỏi `PURGE_DATA_TABLES` và `TelegramMessage` khỏi `PURGE_RECORD_TYPES`; sửa chú thích đang nói "messages" và "HKD mapping" (đã lỗi thời). Không có khoá ngoại từ `telegram_messages` tới các bảng bị xoá, nên xoá giao dịch trước vẫn hợp lệ. Thứ tự xoá giữ nguyên cho các bảng còn lại.

### 3.7 Hiệu năng và dung lượng

- Danh sách dùng index `(telegram_chat_id, sent_at DESC)`, không tải `raw_payload`.
- Khối sức khoẻ: một truy vấn `GROUP BY telegram_chat_id` cho cả 4 chỉ số, cache 1 phút.
- Dung lượng: khoảng 2–4 KB/tin (chủ yếu `raw_payload`); 100.000 tin ≈ 300 MB. Chưa cần dọn. Về sau có thể xoá `raw_payload` của tin cũ hơn N tháng nhưng giữ text (không làm lần này).

### 3.8 Bill tự bỏ qua: lưu bản ghi có tag thay vì bỏ hẳn (G8)

Thay đổi hành vi vừa làm ở `bfa854d` (chưa push, chưa deploy nên **không có dữ liệu cũ cần backfill**).

**Hành vi mới.** Bill từ Telegram mà OCR thấy SmartPOS (`shows_smart_pos`) hoặc thuộc HKD có `skip_bills` vẫn tạo một `Transaction`, nhưng:
- `status = "excluded"` (trạng thái mới), `tags = ["smart_pos"]` hoặc `["skip_merchant"]` (cột mới).
- Chỉ lưu những gì đọc được từ bill: số tiền, thời gian, tên HKD đọc được, HKD khớp (nếu có), số lô, MID/TID, ảnh, tin nhắn gốc, `source_data`.
- **Không** tính phí, không chọn đại lý/loại thẻ, không kiểm trùng, không vào hàng đợi duyệt, không ghi Google Sheet, không vào file Excel.
- Chỉ áp cho document mà trước đây sẽ được tạo giao dịch (settlement có số tiền). Bill con, ảnh unknown, ảnh chuyển khoản vẫn bị bỏ qua như cũ.
- Ảnh upload tay: vẫn xử lý bình thường (không tag).

**Vì sao cần cả tag lẫn trạng thái.**

| | Vai trò |
|---|---|
| `status = "excluded"` | An toàn: mọi nơi đang chọn theo trạng thái (hàng đợi duyệt `needs_review`, Excel `approved/exported`, ghi sheet `approved`) tự động không thấy bản ghi này, không phải sửa từng nơi |
| `tags` (text[], GIN index) | Lý do và cách lọc: `smart_pos`, `skip_merchant`. Thêm tag khác sau này không cần đổi trạng thái |

**Cột/bảng.** `transactions.tags text[] not null default '{}'` + GIN index; thêm `excluded` vào `STATUSES`, check constraint `transactions_status_check` và `TRANSITIONS`:
`excluded → processing` (đưa vào xử lý lại), không có chuyển ngược từ các trạng thái khác sang `excluded`.

**Hiển thị.** Trang "Giao dịch" (`Transactions::Filter`):
- Mặc định `exclude_tags = ["smart_pos", "skip_merchant"]`: ẩn các bản ghi này, không ảnh hưởng số trang và tổng.
- Công tắc "Hiện cả bill đã bỏ qua" và bộ lọc `tag` (chọn một tag, hiện đúng nhóm đó). Filter có tag hoặc trạng thái `excluded` thì không áp ẩn mặc định.
- Dòng có badge "Bỏ qua · SmartPOS" / "Bỏ qua · HKD".
- Trang chi tiết: không có nút duyệt/sửa; có nút "Đưa vào xử lý" (admin/operator) → `excluded → processing`, gỡ tag, chạy `Reprocessor`.

**Backfill / đối soát.**
- `bin/rails hellosmc:include_excluded TAG=smart_pos FROM=2026-10-01 TO=2026-10-31 [DRY_RUN=1]`: đưa các bản ghi theo tag và khoảng ngày vào xử lý (cùng logic nút ở trên), in số lượng trước khi chạy, cần `CONFIRM=yes`.
- Tắt `skip_bills` của một HKD **không** tự động kéo lại các bản ghi cũ; dùng lệnh trên.
- Lọc theo tag + ngày để xuất danh sách đối soát; Excel kết toán vẫn không gồm `excluded`. Xuất riêng danh sách này là việc sau nếu cần.

**Chỗ phải sửa vì thêm trạng thái** (đã rà code):

| Nơi | Vấn đề |
|---|---|
| `Dashboard::Stats` | Dòng đếm "đã xử lý hôm nay" (`where.not(status: pending processing)`), tổng tiền hôm nay (`where.not(status: rejected failed)`) và danh sách "gần đây" sẽ lẫn bản ghi `excluded` → loại `excluded` ra |
| `Transactions::Filter` | Ẩn mặc định, bộ lọc tag (trên) |
| `Transactions::Builder` | `other_fee_calculation?` không còn bỏ qua mà dựng bản ghi `excluded`; `rebuild`/`claimed_by_other_row?` coi bản ghi này là "đã quyết" nên chạy lại OCR không tạo trùng |
| `BillAlbums::Reconciler` | Album có bill kết bị `excluded` vẫn đối chiếu như bình thường (chỉ ảnh hưởng hiển thị) |
| Metadata ảnh `skipped_reason` | Bỏ, thay bằng tag trên bản ghi |

---

## 4. Phương án đã cân nhắc

| | Phương án | Nhược | Chọn |
|---|---|---|---|
| A | Chỉ thêm trang xem, không đổi cách thu | Vẫn mất tin nhóm tắt, tin sửa, update mất khi Redis lỗi | Không |
| **B** | **Sửa receiver + hộp thư webhook + trang Tin nhắn** | Thêm một bảng | **Có** |
| C | Bỏ webhook, dùng `getUpdates` định kỳ | Telegram chỉ giữ update 24 giờ; thêm tiến trình chạy liên tục; mất độ trễ thấp | Không |
| D | Dùng Telegram client API (MTProto, user account) để lấy cả lịch sử và tin bị xoá | Cần tài khoản người thật, vi phạm điều khoản nếu lạm dụng, vận hành phức tạp | Không |
| F | Bill tự bỏ qua chỉ ghi `skipped_reason` vào metadata ảnh (đang có) | Không nằm trong "Giao dịch", khó đối soát, backfill phải chạy lại OCR | Không |
| G | Chỉ thêm tag, giữ trạng thái `needs_review` | Bản ghi vào hàng đợi duyệt, bị tính phí/xuất Excel/ghi sheet nếu ai duyệt nhầm | Không |
| E | Tạo ngay bảng `messages` đa kênh | Đoán trước yêu cầu của kênh chưa có | Không (thêm cột `channel` khi cần) |

---

## 5. Test case

| ID | Tình huống | Kỳ vọng | File |
|---|---|---|---|
| P1 | Parser: text, photo, document ảnh, video, voice, audio, sticker, location, contact | Đúng `kind` | `spec/services/telegram/message_parser_spec.rb` |
| P2 | Parser: reply, forward (user, kênh), tin hệ thống | Đúng `reply_to_message_id`, `forwarded_from`, `kind = service` | idem |
| U1 | Tin text của nhóm tắt | Lưu, `ignored`, không job | `spec/services/telegram/update_receiver_spec.rb` |
| U2 | Ảnh của nhóm tắt | Lưu, không tải, không OCR (như cũ) | idem |
| U3 | Sửa tin chưa có bản gốc | Tạo tin, `edited_at`, audit | idem |
| U4 | Sửa tin đã có | Cập nhật text, `edited_at`, lịch sử trong `raw_payload` | idem |
| U5 | Cùng update gửi hai lần | Một bản ghi | idem |
| U6 | Nhóm lạ tự tạo | Tạo nhóm, lưu tin | idem |
| W1 | Webhook hợp lệ | Có dòng `telegram_updates`, job xếp hàng, `200` | `spec/requests/webhooks/telegram_spec.rb` |
| W2 | Cùng `update_id` hai lần | Một dòng, một lần xử lý | idem |
| W3 | Insert lỗi | `500`, không mất update khi Telegram gửi lại | idem |
| W4 | Dòng `received` quá 5 phút | Job quét xếp lại; `attempts ≥ 5` thì không | `spec/jobs/retry_stuck_telegram_updates_job_spec.rb` |
| M1 | Migration backfill `kind` | Đúng với từng mẫu payload cũ | `spec/migrations/...` hoặc spec model |
| L1 | Danh sách: phân trang, thứ tự | 50/trang, mới nhất trước | `spec/requests/admin/messages_spec.rb` |
| L2 | Từng bộ lọc và kết hợp | Đúng kết quả; giữ khi chuyển trang | idem |
| L3 | Tin ảnh có giao dịch / chuyển tiền | Hiện đúng link | idem |
| L4 | Operator xem được, viewer không; JSON thô chỉ admin | 200/403 đúng | idem |
| L5 | Danh sách không đọc `raw_payload` | Truy vấn không chọn cột đó | idem |
| H1 | Khoảng trống id: 1,2,5 | 2 tin thiếu (id 3, 4) | `spec/services/telegram/collection_health_spec.rb` |
| H2 | 0 hoặc 1 tin; id liên tục; chỉ tin ngoài 7 ngày | 0 thiếu, không lỗi chia/rỗng | idem |
| H3 | Nhóm bật không tin 24 giờ | Cảnh báo im lặng; nhóm tắt thì không | idem |
| H4 | `getMe.can_read_all_group_messages` false/true/lỗi API | Cảnh báo / không / không | idem |
| T1 | Bill SmartPOS từ Telegram | Có 1 `Transaction` `excluded`, tag `smart_pos`, có số tiền/thời gian/HKD; không phí, không đại lý, không job ghi sheet | `spec/services/transactions/other_fee_calculation_spec.rb` |
| T2 | HKD `skip_bills` (khớp tên chính xác và gần đúng ≥ 90%) | Tag `skip_merchant` | idem |
| T3 | Chạy lại OCR cùng ảnh | Không tạo bản ghi thứ hai | idem |
| T4 | Ảnh upload tay SmartPOS | Xử lý bình thường, không tag | idem |
| T5 | Bill con / ảnh unknown của máy SmartPOS | Vẫn bỏ qua, không bản ghi | idem |
| T6 | `excluded` không vào: hàng đợi duyệt, Excel, ghi sheet, Dashboard (đếm, tổng, gần đây) | Không xuất hiện | `spec/services/dashboard/stats_spec.rb`, `spec/services/exports/*`, request specs |
| T7 | Danh sách Giao dịch | Mặc định ẩn tag bỏ qua; công tắc hiện cả; lọc tag; lọc trạng thái `excluded` hiện đúng | `spec/requests/admin/transactions_spec.rb` |
| T8 | "Đưa vào xử lý" / `include_excluded` | `excluded → processing`, gỡ tag, tính phí như bill thường; `DRY_RUN` không đổi gì; không có `CONFIRM` không chạy | spec request + rake |
| T9 | Chuyển trạng thái không hợp lệ vào `excluded` | `InvalidTransition` | `spec/models/transaction_spec.rb` |
| X1 | Purge | Giữ `telegram_messages`; xoá phần còn lại như trước | `spec/lib/tasks/purge_spec.rb` (hoặc kiểm bằng task) |

---

## 6. Rủi ro

| # | Rủi ro | Mức | Giảm thiểu |
|---|---|---|---|
| 1 | Bot bị Privacy mode: thiếu tin dù code đúng | **Cao** | Cảnh báo trên trang; hướng dẫn tắt Privacy mode; ghi chú trong tài liệu vận hành |
| 2 | Khoảng trống id bị hiểu là chắc chắn thiếu | Trung bình | Gọi là "có thể thiếu", ghi rõ nguyên nhân khác (xoá, bot khác) |
| 3 | Lưu toàn bộ hội thoại → dữ liệu cá nhân | Trung bình | Phân quyền mục 3.5; thông báo cho khách biết bot lưu mọi tin; retention là việc sau |
| 4 | Dung lượng DB tăng | Thấp | Ước tính mục 3.7; theo dõi; xoá `raw_payload` cũ là phương án sau |
| 5 | Migration backfill chạy lâu khi nhiều tin | Thấp | Một câu `UPDATE` theo `kind`; bảng hiện nhỏ; chạy trong `db:prepare` khi khởi động `web` (cùng cách các migration trước) |
| 6 | Hộp thư webhook phình | Thấp | Dọn `processed` sau 14 ngày |
| 7 | Hai job xử lý cùng một update | Thấp | `update_id` unique, receiver idempotent; job kiểm `status` trước khi chạy |
| 9 | Quên một nơi đếm theo "không phải rejected/failed" nên số liệu lẫn bản ghi `excluded` | Trung bình | Bảng "chỗ phải sửa" mục 3.8; spec T6; rà lại `where.not(status:` khi implement |
| 10 | Tag/trạng thái bị hiểu là "đã xử lý xong" | Thấp | Badge rõ "Bỏ qua · …", không có nút duyệt; hướng dẫn trong trang |
| 8 | Trang chậm khi bảng lớn | Thấp | Index mục 3.1, không tải `raw_payload`, phân trang |

---

## 7. Triển khai và rollback

Thứ tự code (mỗi bước có spec, merge được riêng):
0. Bill tự bỏ qua → bản ghi `excluded` + tag (mục 3.8): migration `tags`/trạng thái, đổi `Transactions::Builder`, `Filter`, `Dashboard::Stats`, nút/lệnh đưa vào xử lý. Làm trước vì sửa lại hành vi chưa deploy.
1. Migration + parser + receiver (G1–G4).
2. Trang Tin nhắn + khối sức khoẻ.
3. Hộp thư webhook (G5).
4. Sửa lệnh purge (G7) và tài liệu vận hành (hướng dẫn tắt Privacy mode).

Deploy: Coolify chạy `db:prepare` khi `web` khởi động; các cột mới đều nullable/có default nên bản chạy cũ không lỗi trong lúc deploy. Sau deploy: kiểm `getMe` trên trang, gửi thử một tin text vào nhóm tắt và một tin sửa.

Rollback: revert branch; các cột mới và bảng `telegram_updates` có thể để nguyên (không bản cũ nào đọc). Nếu cần gỡ, migration có `down`.

---

## 8. File dự kiến thay đổi

`db/migrate/*_add_message_fields_to_telegram_messages.rb`, `db/migrate/*_create_telegram_updates.rb`, `app/models/transaction.rb`, `app/services/transactions/{builder,filter}.rb`, `app/services/dashboard/stats.rb`, `app/views/admin/transactions/*`, `db/migrate/*_add_tags_and_excluded_status_to_transactions.rb`, `app/models/telegram_message.rb`, `app/models/telegram_update.rb`, `app/models/permissions.rb`, `app/services/telegram/{message_parser,update_receiver,bot_client,collection_health}.rb`, `app/controllers/webhooks/telegram_controller.rb`, `app/jobs/{process_telegram_update_job,retry_stuck_telegram_updates_job}.rb`, `app/controllers/admin/messages_controller.rb`, `app/views/admin/messages/*`, `app/views/admin/telegram_chats/show.html.erb`, `app/views/layouts/admin.html.erb`, `config/routes.rb`, `config/locales/vi.yml`, `lib/tasks/hellosmc.rake`, specs mục 5.

---

## 9. Quyết định cần chốt trước khi code

| # | Câu hỏi | Đề xuất |
|---|---|---|
| 1 | Lưu text của nhóm đang tắt (G1)? | Có |
| 2 | Làm hộp thư webhook (G5)? | Có |
| 3 | Giữ tin nhắn khi xoá dữ liệu giao dịch (G7)? | Có |
| 4 | Ai xem trang Tin nhắn? | Admin và operator; viewer không |
| 5 | Ngưỡng cảnh báo "im lặng" | 24 giờ |
| 6 | Cửa sổ tính "có thể thiếu" | 7 ngày |
| 8 | Bill tự bỏ qua: lưu `excluded` + tag (mục 3.8) thay vì bỏ hẳn? | Có |
| 9 | Ẩn mặc định trong danh sách Giao dịch bằng tag | Có, kèm công tắc "Hiện cả" |
| 10 | Tag cố định `smart_pos`, `skip_merchant` (không cho người dùng tự tạo tag) | Cố định |
| 7 | Import lịch sử từ file export Telegram Desktop | Làm sau |
