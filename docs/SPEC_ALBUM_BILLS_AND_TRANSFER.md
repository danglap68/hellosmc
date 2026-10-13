# Spec: collect nhiều bill con + hình chuyển tiền thành một album, OCR từng ảnh và đối chiếu tổng

Trạng thái: **đã implement**. Khi người dùng gửi cùng lúc nhiều bill con và một hình chuyển tiền tổng kết (Telegram gom thành **album / media group**), hệ thống gom chúng thành một `BillAlbum`, OCR từng ảnh, nhận diện ảnh tổng kết (**`settlement`** kết toán POS **hoặc** **`transfer`** chuyển khoản ngân hàng — một trong hai), và đối chiếu tổng bill con (`child_receipt`) với số tiền tổng kết.

Phạm vi: luồng nhận ảnh từ Telegram (`media_group_id`), pipeline OCR, builder giao dịch, và một trang admin mới để xem album. Không đổi cách tính phí, cách resolve hộ/đại lý/loại thẻ, không đổi file xuất Excel, không đổi snapshot lúc duyệt.

Ví dụ chốt (đúng yêu cầu):

| Ảnh | Loại | Số tiền |
|---|---|---|
| Bill con 1 | child_receipt | 100.000.000 |
| Bill con 2 | child_receipt | 200.000.000 |
| Bill con 3 | child_receipt | 300.000.000 |
| Hình tổng kết | settlement (hoặc transfer) | 600.000.000 |

Kết quả kỳ vọng: **1 giao dịch tổng kết 600M** ở `needs_review` (không auto-approve), album `matched` vì `sum(bill con) == số tiền tổng kết (600M)`.

> **Thuật ngữ:** "bill con" (trong yêu cầu) **= document type `child_receipt`** (biên lai bán lẻ cho một giao dịch thẻ: SALE / THANH TOÁN / BÁN HÀNG). Bill con chỉ là **bằng chứng** để cộng dồn đối chiếu — **không tạo giao dịch**. "Hình tổng kết" = **`settlement`** (kết toán POS) **hoặc** **`transfer`** (chuyển khoản ngân hàng) — nguồn số tiền tổng, **tạo đúng 1 giao dịch**.

## 1. Hiện trạng (root cause)

1. `Telegram::MessageParser` đã đọc `media_group_id` và `TelegramMessage` đã lưu cột `media_group_id`. `TelegramMessage#effective_text` và `#related_transactions` đã biết album (caption chỉ nằm ở ảnh đầu, và flag khi caption đổi). **Nhưng không có entity "album"**: mỗi message vẫn là một `BillImage` riêng, OCR riêng, build riêng.
2. `BillVision::Prompt::DOCUMENT_TYPES` chỉ có `settlement | child_receipt | unknown`. Không có loại **hình chuyển tiền / sao kê chuyển khoản** (`transfer`). Prompt hiện chỉ đọc biên lai POS; ảnh chuyển khoản ngân hàng sẽ bị trả về `unknown` hoặc `child_receipt`, gây review sai hoặc tạo giao dịch sai.
3. Không có bước **đối chiếu**: mỗi settlement được `Transactions::Builder` auto-approve độc lập theo độ tin cậy riêng; không ai kiểm tra tổng bill con có khớp số tiền đã chuyển hay không.

## 2. Yêu cầu

1. Khi người dùng gửi một album (các message cùng `media_group_id`), gom tất cả thành một **album** duy nhất.
2. OCR **từng ảnh** trong album như hiện tại (mỗi ảnh vẫn là một `BillImage`).
3. Nhận diện thêm loại tài liệu `transfer` (chuyển khoản ngân hàng) trong prompt/normalizer, bên cạnh `settlement` (kết toán POS) đã có.
4. Bill con (`child_receipt`) **không** tạo giao dịch — chỉ là bằng chứng để cộng dồn; ảnh tổng kết (`settlement` trong album hoặc `transfer`) **tạo đúng 1 giao dịch**.
5. Đối chiếu: `tổng các bill con (child_receipt) trong album == số tiền tổng kết (settlement hoặc transfer)`. Khớp → album `reconciled`; lệch → đưa giao dịch tổng kết về review với lý do rõ ràng.
6. Album không có hình chuyển tiền tổng kết hợp lệ — thiếu hẳn (`no_transfer`) hoặc ảnh chuyển tiền bị duplicate (`transfer_duplicate`) — → **skip**: không tạo giao dịch con, album sang trạng thái `skipped` để admin theo dõi. Không chặn/lỗi luồng.
7. Có trang admin để xem album, các bill con, ảnh chuyển tiền, và kết quả đối chiếu.

## 3. Model / schema

### 3.1 Bảng mới `bill_albums`

| Cột | Kiểu | Ý nghĩa |
|---|---|---|
| `telegram_chat_id` | bigint, FK, null: false | Chat chứa album |
| `media_group_id` | string, null: false | ID media group Telegram |
| `status` | string, default `collecting` | `collecting` (đang nhận ảnh) → `processing` (đang OCR) → `reconciled` / `needs_review` / `skipped` / `failed` |
| `collect_until` | datetime | Mốc hết thời gian chờ ảnh mới của album (debounce). Mỗi message mới đẩy mốc này ra xa thêm `album_collect_window_seconds`. |
| `reconciliation_status` | string, null | `matched` / `mismatched` / `multiple_transfers` / `missing_bills` / `no_transfer` / `transfer_duplicate` / `incomplete` |
| `transfer_bill_image_id` | bigint, FK → bill_images, null | Ảnh được xác định là hình chuyển tiền |
| `transfer_amount_vnd` | bigint, null | Số tiền đọc từ ảnh transfer |
| `child_total_vnd` | bigint, null | Tổng các bill con (`child_receipt`) |
| `child_count` | integer, default 0 | Số bill con (`child_receipt`) trong album |
| `transfer_count` | integer, default 0 | Số tài liệu transfer trong album |
| `match_difference_vnd` | bigint, null | `child_total_vnd - transfer_amount_vnd` khi lệch |
| `metadata` | jsonb, default `{}` | Thông tin phụ (message ids, lý do, …) |
| `created_at` / `updated_at` | datetime | |

Unique index `(telegram_chat_id, media_group_id)`. Index `status`, `reconciliations_status` không cần thiết vì khối lượng nhỏ, chỉ index theo `telegram_chat_id`.

Check constraint cho `status`: `collecting | processing | reconciled | needs_review | skipped | failed`.
Check constraint cho `reconciliation_status`: null hoặc `matched | mismatched | multiple_transfers | missing_bills | no_transfer | transfer_duplicate | incomplete`.

### 3.2 Đổi bảng `bill_images`

Thêm cột `bill_album_id` (bigint, FK → bill_albums, nullable, index). `BillImage belongs_to :bill_album, optional: true`. Ảnh ngoài album (tin nhắn đơn lẻ) để null và giữ nguyên luồng cũ.

### 3.3 Quan hệ model

- `BillAlbum belongs_to :telegram_chat`
- `BillAlbum has_many :bill_images, dependent: :nullify`
- `BillAlbum has_many :transactions, through: :bill_images` (để flag / hiển thị toàn bộ giao dịch của album)
- `BillImage belongs_to :bill_album, optional: true`

Không thêm cột `bill_album_id` vào `transactions`: truy cập qua `bill_image` là đủ. Mỗi giao dịch con vẫn giữ `telegram_message_id` và `bill_image_id` như cũ.

### 3.4 Setting mới

| Key | Default | Ý nghĩa |
|---|---|---|
| `album_collect_window_seconds` | `15` | Thời gian chờ ảnh mới của album trước khi chốt (debounce) |

Thêm vào trang `settings` và `AppConfig` (`AppConfig.album_collect_window_seconds`). Không đặt quá nhỏ để tránh album bị xé lẻ khi webhook đến chậm.

## 4. Luồng xử lý

### 4.1 Collect (gom album)

Trong `Telegram::UpdateReceiver#call`, ngay sau `persist_message` khi `created` là `true` và `parsed.image?` và `parsed.media_group_id.present?`, gọi `BillAlbums::Collector.call(message)`:

1. Find-or-create `BillAlbum` theo `(telegram_chat, media_group_id)` (xử lý race bằng `create!` + `rescue ActiveRecord::RecordNotUnique` giống `upsert_chat` hiện tại).
2. `album.collect_until = Time.current + AppConfig.album_collect_window_seconds.seconds` (mỗi message mới kéo dài thêm).
3. Lưu danh sách `telegram_message_id` vào `metadata["message_ids"]`.

Collector **chỉ gom album, không enqueue finalize**. Finalize được kích hoạt từ `DownloadTelegramAttachmentJob` và `AnalyzeBillImageJob` (mục 4.2) — tức chỉ sau khi ảnh bắt đầu được tải. Nhờ vậy album của chat chưa active (ảnh lưu tạm, chưa download) không bị chốt nhầm thành `skipped`; khi admin `process_stored` → download → analyze → finalize chạy bình thường.

`Telegram::AttachmentDownloader`: khi tạo `BillImage`, nếu message có `media_group_id` và album đã tồn tại thì gán `bill_image.bill_album_id = album.id`.

`DownloadTelegramAttachmentJob#perform`: sau khi `AttachmentDownloader.call` trả về `BillImage` (kể cả ảnh duplicate), nếu `bill_image.bill_album_id` thì enqueue `FinalizeBillAlbumJob.perform_later(bill_image.bill_album_id)`.

### 4.2 Analyze (OCR từng ảnh)

Không đổi `DownloadTelegramAttachmentJob` → `AnalyzeBillImageJob` → `BillImages::Analyzer` → `BillVision::Pipeline`. Chỉ đổi **điểm rẽ nhánh sau khi phân tích xong** trong `AnalyzeBillImageJob#perform`:

```ruby
if result.status.in?(%i[analyzed failed])
  if bill_image.bill_album_id
    FinalizeBillAlbumJob.perform_later(bill_image.bill_album_id)
  else
    BuildTransactionJob.perform_later(bill_image.id)
  end
end
```

Ảnh thuộc album **không** build ngay mà để album chốt build toàn bộ một lượt (để đối chiếu được trọn vẹn). Ảnh ngoài album giữ nguyên hành vi cũ.

Lưu ý: `AnalyzeBillImageJob` còn có khối `retry_on BillVision::TransientError do ... end` đang enqueue `BuildTransactionJob` trực tiếp khi hết lượt retry. Phải đổi luôn nhánh này theo cùng quy tắc: ảnh thuộc album → `FinalizeBillAlbumJob`; ảnh ngoài album → giữ `BuildTransactionJob`.

### 4.3 Finalize (chốt album)

`FinalizeBillAlbumJob#perform(album_id)`:

1. Load album. Trả về ngay nếu album đã ở trạng thái kết thúc (`reconciled` / `needs_review` / `skipped` / `failed`) và không `force`.
2. Nếu `Time.current < album.collect_until` → trì hoãn lại (`wait: album.collect_until - Time.current`) và trả về (vẫn đang chờ ảnh mới).
3. Nếu còn `TelegramMessage` thuộc album chưa có `BillImage` (download chưa xong) → trì hoãn lại (backoff ngắn, ví dụ `wait: 5.seconds`) và trả về. Không chốt khi album còn thiếu ảnh chưa tải.
4. Nếu còn `bill_image` chưa kết thúc OCR (`pending` / `processing`) → trì hoãn lại (backoff ngắn) và trả về. Giới hạn số lần chờ bằng style retry của job để tránh lặp vô hạn.
5. Khi đủ điều kiện, gọi `BillAlbums::Reconciler.call(album)`.

**Luồng tương đương khi có ảnh fail OCR:** vẫn chốt album (không chờ vô hạn) — `Reconciler` xử lý trường hợp ảnh fail thành `incomplete`.

### 4.4 Build giao dịch con (trong finalize)

Build do `Reconciler` quyết định (xem mục 6): chỉ gọi `Transactions::Builder` khi album có transfer và có ít nhất một bill con (`transfer_count >= 1` và `child_count >= 1`). Builder đã đổi để **bỏ qua tài liệu `transfer`** và **không skip `child_receipt` khi ảnh thuộc album** (mục 5.3). Kết quả: mỗi bill con (`child_receipt`) thành một `Transaction` ở trạng thái `needs_review` (**không auto-approve** — bill con luôn cần duyệt thủ công), mỗi ảnh `transfer` không sinh transaction; album không có transfer (chỉ toàn bill con) thì **không gọi Builder** — skip, không tạo giao dịch con.

## 5. OCR — loại tài liệu `transfer`

### 5.1 `BillVision::Prompt`

- `DOCUMENT_TYPES = %w[settlement child_receipt transfer unknown].freeze`.
- `SYSTEM` bổ sung định nghĩa `transfer`: ảnh chụp / sao kê chuyển khoản ngân hàng — nhãn như `Chuyển tiền`, `Chuyển khoản`, `Ủy nhiệm chi`, `Lệnh chuyển tiền`, `Giao dịch thành công`, màn hình app ngân hàng có người gửi/người nhận. `total_amount_vnd` = số tiền đã chuyển (số nguyên VND, bỏ dấu phân cách), `transaction_date`/`transaction_time` = ngày/giờ chuyển. `merchant_name`, `lot_number`, `terminal_or_merchant_id` = null cho transfer.
- `USER` và `SCHEMA` không đổi (schema đã dùng `Prompt::DOCUMENT_TYPES` và `FIELDS`, tự kế thừa `transfer`).

### 5.2 `BillVision::Normalizer`

- Thay `CRITICAL_FIELDS` (hằng số dùng chung) bằng map theo loại tài liệu:

| document_type | critical fields |
|---|---|
| `settlement` | `document_type, total_amount_vnd, merchant_name, transaction_date, transaction_time` |
| `transfer` | `document_type, total_amount_vnd, transaction_date` |
| `child_receipt` / `unknown` | `document_type` |

- Cả `low_confidence_fields` **và** `critical_confidence` đều dùng map theo loại này (hiện tại cả hai đang dùng chung hằng `CRITICAL_FIELDS` cho mọi loại). Với `transfer`, không yêu cầu `merchant_name` và không yêu cầu bắt buộc `transaction_time`.
- `critical_value` giữ nguyên logic `merchant_name` vs `terminal_or_merchant_id` chỉ áp dụng cho `settlement`.
- `child_receipt` giữ nguyên critical fields (`document_type`): amount/merchant/date/time của bill con vẫn được `Evaluator` kiểm tra bằng `flag_confidence` (thiếu/không đọc được → `amount_missing`/`amount_unreadable`…), nên không cần nâng critical fields ở Normalizer.

### 5.3 `Transactions::Builder`

- `first_build` và `rebuild`: bỏ qua (`next`) các document "tổng kết" — `transfer`, và `settlement` **khi ảnh thuộc album** (`total_document?`) — không tạo transaction.
- `skippable_child_receipt?`: chỉ skip `child_receipt` khi ảnh **không thuộc album** (luồng ảnh đơn như hiện tại). Khi ảnh thuộc album, `child_receipt` là bill con → **không skip**, build thành transaction (vẫn vào `needs_review`, không auto-approve — xem 5.4).
- `settlement` ở ảnh đơn (không thuộc album) vẫn build thành transaction như hiện tại; `settlement` trong album là "tổng kết" → không build.

### 5.4 `Transactions::Evaluator` và `BillVision::ValidationPolicy`

- `Evaluator`: thêm guard — `transfer` không được đánh giá kế toán (không resolve merchant/dealer/fee). Builder đã bỏ qua trước khi gọi, nên đây chỉ là lớp bảo vệ (raise/return no-op).
- `Evaluator#check_document_type`: `child_receipt` (bill con) **giữ nguyên** `document_type_uncertain` → luôn vào review, **không auto-approve** (kể cả trong album lẫn ảnh đơn). Không cần đổi xử lý `child_receipt` ở Evaluator.
- `ValidationPolicy`: với document `transfer`, **bỏ qua** `Transactions::Evaluator` (không có hộ/đại lý/phí); chỉ thêm lý do visual: `transfer_amount_unreadable` (thiếu `total_amount_vnd`), `transfer_date_unreadable` (thiếu `transaction_date`). Không thêm `merchant_unreadable` cho transfer. Với `child_receipt` thuộc album, **không** bỏ qua theo nhánh `next if child_receipt && !requires_review` như ảnh đơn — vẫn chạy validation (để bắt amount/date/time không đọc được).

## 6. Đối chiếu (reconciliation)

`BillAlbums::Reconciler.call(album)` — pure logic + persist album + flag, không tính phí:

1. `images = album.bill_images.analyzable` (để đọc document). `duplicate_images = album.bill_images.where.not(duplicate_of_id: nil)` (để phát hiện ảnh tổng kết bị dedup).
2. Quét `normalized_extraction["documents"]` của mọi ảnh `images`:
   - `child_receipt` (bill con) → cộng `child_total_vnd`, `child_count += 1`; nếu `total_amount_vnd == nil` → `amount_missing = true`.
   - `settlement` / `transfer` (ảnh tổng kết) → `total_count += 1`; gom số tiền tổng (chỉ gán `transfer_amount_vnd` khi đúng 1 ảnh tổng kết; nhiều ảnh thì lưu list vào `metadata["total_amounts"]`).
   - `unknown` → bỏ qua.
3. Nếu `total_count == 0`, kiểm tra `duplicate_images`: nếu có ảnh duplicate mà `duplicate_of.documents` chứa document `settlement` hoặc `transfer` → `total_duplicate = true` (người dùng có gửi ảnh tổng kết nhưng bị dedup).
4. Nếu `total_count >= 1` và `child_count >= 1` → gọi `Transactions::Builder.call(bill_image:)` cho từng ảnh `images` (idempotent; Builder đã bỏ qua ảnh tổng kết và không skip `child_receipt` trong album — mục 5.3; ảnh `failed` → Builder tự tạo placeholder `failed`). Không gọi Builder khi `total_count == 0` (skip).
5. Ra quyết định theo **thứ tự ưu tiên** sau (điều kiện đầu tiên khớp sẽ thắng):

| # | Điều kiện | `reconciliation_status` | `status` | Hành động |
|---|---|---|---|---|
| 1 | `total_count == 0` và `total_duplicate` | `transfer_duplicate` | `skipped` | **Skip**: không build, không flag; ghi lý do "ảnh tổng kết bị duplicate" vào `metadata`. |
| 2 | `total_count == 0` | `no_transfer` | `skipped` | **Skip**: không build (bước 4 đã bỏ), lưu `child_count`/`child_total_vnd` để admin xem, không flag. Thắng cả khi có ảnh fail hay `amount_missing`. |
| 3 | có ảnh `ocr_failed?` | `incomplete` | `needs_review` | Đã build ở bước 4; flag `album_ocr_failed` lên các giao dịch con đã build. Không đối chiếu số. |
| 4 | `total_count > 1` | `multiple_transfers` | `needs_review` | Đã build; flag `album_multiple_transfers`. |
| 5 | `child_count == 0` | `missing_bills` | `needs_review` | Không có bill con; chỉ ghi trạng thái album (không gọi Flagger vì không có giao dịch). |
| 6 | `amount_missing` | `incomplete` | `needs_review` | Đã build; flag `album_amount_unreadable`. |
| 7 | tổng khớp (`child_total_vnd == transfer_amount_vnd`) | `matched` | `reconciled` | Đã build; không flag. |
| 8 | tổng lệch | `mismatched` | `needs_review` | Đã build; flag `album_total_mismatch`. |

- Khớp = so **số nguyên VND tuyệt đối**, không dùng khoảng sai số. `match_difference_vnd = child_total_vnd - transfer_amount_vnd`.
- Album `matched`/`reconciled` chỉ nghĩa là **tổng khớp**; các transaction con (`child_receipt`) vẫn ở `needs_review` (không auto-approve) và được duyệt thủ công riêng. Khi `mismatched`/`multiple_transfers`/`incomplete`, ngoài việc bill con đã ở `needs_review`, `Flagger` còn cộng thêm lý do album vào review.
- **Skip** (`no_transfer` / `transfer_duplicate`) nghĩa là không ghi sổ bill con; album dừng ở `skipped` (không phải lỗi, không chặn luồng). `no_transfer` = không có hình tổng kết; `transfer_duplicate` = có hình tổng kết nhưng bị trùng (dedup). Admin có thể yêu cầu gửi lại hình chuyển tiền. Ảnh chuyển tiền gửi bổ sung sau (update/edit Telegram không thêm ảnh mới vào media group cũ) tạo album mới — nằm ngoài phạm vi, xem mục 12.
- "Flag" chỉ áp dụng khi có giao dịch con (`album.transactions`): `Transactions::Flagger.call(transactions: album.transactions, reason: ...)`. Với `no_transfer`/`transfer_duplicate`/`missing_bills` không có giao dịch thì không gọi Flagger, chỉ lưu trạng thái album. `Flagger` hiện tại xử lý đúng: `approved → hold` + review `held`; `needs_review/hold/failed` → cộng thêm reason; dòng `processing` bị bỏ qua (nhưng finalize build trước rồi mới flag nên không còn dòng `processing`). Vì bill con (`child_receipt`) luôn ở `needs_review`, flag trong album thực tế luôn rơi nhánh "cộng thêm reason" (không có nhánh `approved → hold`).
- Ghi `transfer_bill_image_id`, `transfer_amount_vnd`, `child_total_vnd`, `child_count`, `transfer_count`, `match_difference_vnd`, `reconciliation_status`, `status`.
- `AuditLogger.log!(action: "bill_album.reconciled", auditable: album, ...)` + `StructuredLog`.

**Quy tắc vàng giữ nguyên:** không sửa số tiền của bất kỳ giao dịch con nào; đối chiếu chỉ thêm cảnh báo/review, không tự sửa dữ liệu kế toán.

### 6.x Bill kết đầy đủ thì bỏ bill con (bổ sung)

Một bill kết (`settlement`) được coi là **đầy đủ** khi OCR bóc được cả sáu trường:
số tiền, tên HKD, TID/MID (`terminal_or_merchant_id`), số lô, ngày, giờ
(`Transactions::Builder.complete_settlement?`). Tên đại lý (số ở cuối tên HKD) **không bắt buộc**:
màn hình POS hay cắt tên ("THIÊN KIM…"); không xác định được đại lý thì giao dịch vào review
(`dealer_unmapped`), bill con không được dùng để tìm đại lý.

- **Đầy đủ** (đúng một bill kết): bill con bị bỏ, không cộng tổng/đối chiếu. Album `reconciled`,
  `reconciliation_status = settlement_complete`, `metadata.children_dropped = true`. Giao dịch
  được xét như ảnh đơn, không có lý do `album_total_review`.
- **Thiếu bất kỳ trường nào**: giữ bill con để điền phần thiếu (merchant, lô, giờ) và đối chiếu tổng
  như mô tả ở mục 6; giao dịch vẫn có `album_total_review`.
- Thứ tự quyết định: không có tổng → `skipped`; có ảnh OCR lỗi → `incomplete`; nhiều tổng →
  `multiple_transfers`; đầy đủ → `settlement_complete`; còn lại theo mục 6.

## 7. Admin

- `Admin::BillAlbumsController` (`index`, `show`) + route `resources :bill_albums, only: %i[index show]`.
- `index`: danh sách album gần nhất, cột `status`, `reconciliation_status`, tổng con, số tiền chuyển, chênh lệch, chat, thời điểm. Album `skipped` (thiếu hình tổng kết) hiện rõ để admin theo dõi/yêu cầu gửi bổ sung.
- `show`: hiển thị từng ảnh (bill con + ảnh chuyển tiền được đánh dấu), kết quả OCR từng ảnh, bảng tổng `child_total_vnd` vs `transfer_amount_vnd` và `match_difference_vnd`; link tới từng `Transaction` con. Album `skipped` hiển thị tổng bill con đã đọc nhưng ghi chú "chưa ghi sổ do thiếu hình chuyển tiền".
- Trang `Transaction#show` (và bảng giao dịch) hiển thị badge album + trạng thái đối chiếu nếu có, link tới album.
- Badge dịch trong `config/locales/vi.yml`; enum lưu tiếng Anh trong DB như quy ước hiện tại.

## 8. Test case

### 8.1 Collector

- N message cùng `media_group_id` → đúng 1 `BillAlbum`, `metadata["message_ids"]` đủ N.
- Hai `media_group_id` khác nhau → 2 album.
- Message ảnh không có `media_group_id` → không tạo album.
- Message thứ 2 cùng album kéo dài `collect_until`.

### 8.2 Debounce / finalize

- `FinalizeBillAlbumJob` chạy trước `collect_until` → không chốt, trì hoãn lại.
- Còn `TelegramMessage` chưa có `BillImage` (chưa download) → không chốt, trì hoãn lại.
- Còn `bill_image` đang `processing` → không chốt, trì hoãn lại.
- Chat chưa active: Collector không enqueue finalize; album nằm `collecting` cho tới khi admin `process_stored`.
- Chạy job 2 lần sau khi đã chốt → không build/flag lần 2 (idempotent).

### 8.3 OCR `transfer`

- Normalizer: ảnh transfer → document_type `transfer`, `total_amount_vnd` đọc đúng, không đòi `merchant_name`; `merchant_name/lot_number/terminal_or_merchant_id` null không gây review.
- `OutputSchema.valid?` chấp nhận document có `document_type: "transfer"`.
- `ValidationPolicy`: transfer thiếu amount → `transfer_amount_unreadable`, không có `merchant_unreadable`.

### 8.4 Builder

- Ảnh chỉ chứa transfer → không tạo transaction.
- Ảnh chứa bill con (`child_receipt`) + transfer → chỉ tạo transaction cho `child_receipt`.
- Multi child_receipt trong một ảnh thuộc album → vẫn ra đủ N giao dịch con.
- Ảnh đơn chứa `child_receipt` confident → vẫn bị skip (giữ nguyên hành vi ảnh đơn).

### 8.5 Reconciler — ví dụ chốt

- 3 bill con (`child_receipt`: 100M / 200M / 300M) + transfer 600M → `matched`, `child_total_vnd = 600_000_000`, 3 transaction `needs_review` (không auto-approve vì là `child_receipt`), không flag thêm.
- 3 bill con 600M + transfer 500M → `mismatched`, `match_difference_vnd = +100_000_000`, cộng thêm reason `album_total_mismatch` vào review của các bill con (đang `needs_review`).
- 2 ảnh transfer → `multiple_transfers`, flag.
- transfer không kèm bill con (`child_receipt`) → `missing_bills`, chỉ ghi trạng thái album (không có giao dịch để flag).
- album không có transfer (chỉ toàn bill con `child_receipt`) → `no_transfer` + `status = skipped`, **không tạo transaction con**, không flag.
- album không có transfer nhưng có 1 ảnh OCR failed → vẫn `skipped` (skip thắng), không tạo transaction.
- album có ảnh transfer nhưng ảnh đó bị dedup (duplicate, `duplicate_of.documents` chứa `transfer`) → `transfer_duplicate` + `status = skipped`, không tạo transaction, `metadata["skip_reason"] = "transfer_duplicate"`.
- 1 ảnh OCR failed + có transfer + bill con → `incomplete`, bill con khoẻ vẫn được build (`needs_review`), cộng thêm reason `album_ocr_failed`.
- transfer + bill con thiếu amount → `incomplete`, flag `album_amount_unreadable`.

**Bổ sung (edge cases):**

- Bill con nằm rải nhiều ảnh (2 bill trong ảnh A + 1 bill trong ảnh B) + transfer → vẫn cộng đủ 3 bill (`child_total_vnd` đúng, không phụ thuộc số ảnh).
- Album có `settlement` + `child_receipt` + transfer → `settlement` **không** cộng vào `child_total_vnd`; `settlement` vẫn được book riêng thành transaction (luồng ảnh đơn).
- Bill con ghi `100.000.000` (dấu chấm phân cách) → Normalizer ra `100_000_000`, cộng đúng.
- Tổng bill con < transfer (500M vs 600M) → `mismatched`, `match_difference_vnd = -100_000_000`.
- 2 ảnh transfer khác số tiền → `multiple_transfers`, `metadata["transfer_amounts"]` ghi cả hai.
- Ảnh trong album không có document nào (OCR trả `documents: []`) → không đóng góp gì, không phá đối chiếu.
- Ảnh transfer dedup mà `duplicate_of.documents` **không** chứa `transfer` (ví dụ trùng bytes với ảnh settlement) → không coi là `transfer_duplicate`, rơi `no_transfer`.
- Có đúng 1 transfer → `transfer_bill_image_id` trỏ đúng ảnh transfer đó.

### 8.6 Job routing

- Ảnh có album: sau download và sau analyze đều enqueue `FinalizeBillAlbumJob`, không enqueue `BuildTransactionJob` trực tiếp.
- Ảnh không có album: giữ nguyên enqueue `BuildTransactionJob`.
- `AnalyzeBillImageJob#retry_on` (hết retry transient) và `RetryFailedExtractionJob#release_stuck` với ảnh thuộc album → route qua finalize.

### 8.7 Card type / dealer / merchant (album)

- Album caption `MB` (chỉ ảnh đầu có caption) → mọi bill con trong album resolve card type `mb`.
- Sửa caption album (đổi `MB` → `Napas`) → flag tất cả transaction con của album bằng `caption_edited` (qua `related_transactions` hiện có).
- Chat chưa map dealer → bill con có reason `dealer_unmapped`, vào review.
- Bill con có merchant không khớp (không tìm thấy) → reason `merchant_not_found`, vào review.

### 8.8 Concurrency / idempotency

- Hai `FinalizeBillAlbumJob` chạy đồng thời → chỉ một lần reconcile, không tạo transaction trùng, không flag 2 lần.
- Finalize chạy lại sau khi album đã `reconciled`/`needs_review`/`skipped` → early-return, không đổi gì.
- Reprocess 1 ảnh trong album (force re-OCR) → `AnalyzeBillImageJob` route qua finalize; `Reconciler` build lại (Builder chỉ rebuild dòng `processing`), đối chiếu chạy lại.

### 8.9 Admin

- Album index: hiện đủ cột `status`, `reconciliation_status`, `child_total_vnd`, `transfer_amount_vnd`, `match_difference_vnd`; album `skipped`/`mismatched` hiện rõ.
- Album show: liệt kê từng ảnh (đánh dấu ảnh transfer), bảng tổng con vs số chuyển + chênh lệch, link tới từng transaction con.
- Trang transaction con: hiển thị badge album + trạng thái đối chiếu, link tới album.

## 9. Ngoài phạm vi

- Không đối chiếu transfer nằm **trong cùng một ảnh** với nhiều bill (single-image multi-document): transfer trong ảnh đơn vẫn được OCR và bị Builder bỏ qua, nhưng không chạy reconciliation vì không có album. (Điểm mở — xem mục 12.)
- Không tự cộng nhiều ảnh transfer thành một tổng khi album có >1 transfer (đưa review, không đoán).
- Không đổi `Transactions::Calculator`, `FeeRules::Resolver`, `Dealers::Resolver`, `CardTypes::Resolver`.
- Không đổi file xuất Excel / Google Sheet (`SPEC_HELLO_SMC_WORKBOOK.md`) — album không tham gia xuất.
- Không gộp ảnh thành một file ảnh duy nhất trên storage (mỗi ảnh vẫn lưu riêng; "album" là liên kết logic, không phải ảnh ghép).
- Không xử lý album manual upload nhiều ảnh trong spec này (`BillUploadForm` hiện upload 1 ảnh).
- Không sửa `processing_status` của `TelegramMessage` ngoài các trạng thái hiện có.
- Không đổi luồng ảnh đơn `settlement` (kết toán ca): ảnh đơn vẫn book 1 transaction/settlement như hiện tại. Trong album, `settlement` là ảnh tổng kết (không book, dùng để đối chiếu).

## 10. Thứ tự implement

1. Migration `bill_albums` + `bill_images.bill_album_id`; model `BillAlbum` + associations + enums + scopes.
2. `BillAlbums::Collector` + hook vào `UpdateReceiver`; link `bill_album_id` trong `AttachmentDownloader`.
3. Setting `album_collect_window_seconds` + `AppConfig`.
4. Prompt/Normalizer/OutputSchema/Evaluator/ValidationPolicy: thêm `transfer` (OutputSchema tự kế thừa); nâng critical fields của `child_receipt` bằng `settlement`; Evaluator/ValidationPolicy xử lý `child_receipt` như `settlement` khi ảnh thuộc album.
5. `Transactions::Builder`: bỏ qua document `transfer`; không skip `child_receipt` khi ảnh thuộc album.
6. `FinalizeBillAlbumJob` + `BillAlbums::Reconciler`; đổi routing trong `DownloadTelegramAttachmentJob`, `AnalyzeBillImageJob` (kể cả khối `retry_on`) và `RetryFailedExtractionJob`.
7. Admin `bill_albums` (controller, views, routes, locales) + badge trên transaction.
8. Spec mục 8 (unit + integration), fixture `transfer` (ảnh + JSON extraction), fixture album nhiều message.

## 11. Quyết định đã khóa

| # | Quyết định |
|---|---|
| 1 | Album = `(telegram_chat_id, media_group_id)`. |
| 2 | Ảnh tổng kết (`settlement` trong album hoặc `transfer`) không tạo transaction; chỉ là bằng chứng + nguồn đối chiếu. |
| 3 | Album không có ảnh tổng kết (chỉ toàn bill con) → **skip**: không tạo giao dịch con, `status = skipped`, `reconciliation_status = no_transfer`. Không chặn/lỗi luồng. |
| 4 | Khớp = số nguyên VND tuyệt đối, không khoảng sai số. |
| 5 | `child_total_vnd` = tổng các **bill con (`child_receipt`)** trên mọi ảnh của album (một ảnh có thể chứa nhiều bill con). |
| 6 | Lệch/missing/multiple/incomplete → `Transactions::Flagger` cộng thêm reason vào review của bill con (đang `needs_review`). Không tự sửa số tiền. |
| 7 | `transfer` critical fields = `document_type, total_amount_vnd, transaction_date` (không bắt `merchant_name`, không bắt buộc `transaction_time`). |
| 8 | Album được chốt bằng debounce `album_collect_window_seconds` (default 15s) + chờ download + chờ OCR; finalize được kích hoạt từ download/analyze job (không từ collector), idempotent. |
| 9 | Build giao dịch con của album chỉ chạy từ `FinalizeBillAlbumJob` — mọi nhánh build (`AnalyzeBillImageJob`, khối `retry_on` transient, `RetryFailedExtractionJob`) đều route qua finalize khi ảnh thuộc album. |
| 10 | "bill con" = `child_receipt` (biên lai bán lẻ). Trong album, `child_receipt` được build thành transaction nhưng **không auto-approve** (luôn `needs_review`); "hình tổng kết" = `settlement` (kết toán POS) **hoặc** `transfer` (chuyển khoản ngân hàng) — nguồn đối chiếu động, không tạo transaction. |
| 11 | Ảnh transfer bị dedup (SHA256 / `telegram_file_unique_id` trùng) → skip với `reconciliation_status = transfer_duplicate`, lý do "hình chuyển tiền bị duplicate". Không đọc số tiền từ `duplicate_of` gốc. |

## 12. Rủi ro / điểm mở

1. **Telegram không báo số ảnh / không có marker kết thúc album.** Debounce là heuristic; album rất lớn hoặc mạng chậm có thể bị xé lẻ. Cần theo dõi `collect_until` và log.
2. **Ảnh chuyển khoản ngân hàng rất đa dạng** (MB Bank, Techcombank, ví, VNPay, ủy nhiệm chi…). Độ tin cậy OCR transfer ban đầu có thể thấp → nhiều review hơn; cần thêm fixture thật để chỉnh prompt.
3. **Nhiều transfer trong một album** (chuyển làm nhiều lần) hiện đưa review, chưa tự cộng. Có thể mở rộng sau khi có dữ liệu thật.
4. **Transfer nằm chung ảnh với bill con** chưa được đối chiếu (ngoài phạm vi). Có thể nâng cấp `Reconciler` để chạy cả trên single-image multi-document.
5. **Album chỉ toàn bill con (= `child_receipt`, không có hình tổng kết)** bị skip, không ghi sổ. Đã chốt: không chặn luồng, nhưng không tạo giao dịch. Điểm mở còn lại: ảnh chuyển tiền được gửi **bổ sung sau đó** (không cùng media group cũ) sẽ tạo album mới chứ không ghép vào album đã skip — cần xác nhận cách khớp ảnh bổ sung nếu nghiệp vụ có tình huống này.
6. **Ảnh transfer bị dedup (SHA256/file_unique_id trùng)** → đã chốt: skip với `reconciliation_status = transfer_duplicate` (lý do "hình chuyển tiền bị duplicate"), không đọc số tiền từ `duplicate_of` gốc. Phát hiện bằng cách xem `duplicate_of.documents` có document `transfer` không.
