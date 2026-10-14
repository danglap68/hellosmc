# Spec kỹ thuật: Phân loại "đi tiền" / "kết toán" và ghi lệnh chuyển tiền vào Hello SMC

| | |
|---|---|
| Trạng thái | Đã implement; suite lần đầu 22 fail, đã sửa (§7.2), **cần chạy lại** |
| Ngày | 11–12/10/2026 |
| Phạm vi | Nhận ảnh Telegram, OCR, model mới `RemitterTransfer`, ghi Google Sheet (`thu chi {ngày}{tháng}`, `DS MB T{tháng}`, `MB`), admin "Chuyển tiền" |
| Thay thế | `SPEC_HELLO_SMC_WORKBOOK.md` §7.2 và §18 (ghi `thu chi` từ transaction) |
| Liên quan | `SPEC_ALBUM_BILLS_AND_TRANSFER.md` (album của đại lý giữ nguyên) |

---

## 1. Bối cảnh và yêu cầu

Trong group Telegram có hai loại ảnh:

| Loại | Ai gửi | Nội dung | Kết quả mong muốn |
|---|---|---|---|
| **Kết toán** | Đại lý | Bill kết toán POS (hoặc album bill con + tổng kết) | Tạo transaction, tính phí, ghi `DS MB` + `MB` |
| **Đi tiền** | Người đi tiền (Lập, Kim, An, Yến, Cô Tuyết…) | Ảnh màn hình chuyển khoản ngân hàng, tin nhắn kèm mã (`TK01`) | **Không** tạo transaction; cộng số tiền vào báo cáo `thu chi` theo đại lý × người đi tiền |

Yêu cầu đã chốt với người dùng:

1. Khi nhận ảnh phải phân loại được đi tiền hay kết toán. Lệnh đi tiền không tạo transaction.
2. Người đi tiền ghi **mã chuyển tiền** trong tin nhắn Telegram gửi kèm ảnh. Mã cho biết **HKD + đại lý**. Người đi tiền xác định theo `telegram_user_id` hoặc `telegram_username`.
3. OCR chỉ cần **số tiền**. Không cần nội dung chuyển khoản, chi tiết giao dịch, ngày trên biên lai.
4. Độ tin cậy số tiền **≥ 92%** thì tự duyệt, thấp hơn phải review.
5. Tab `thu chi {ngày}{tháng}`: mỗi lệnh **chèn một hàng** trong khối đại lý, `TOTAL` phải tính đủ.
6. `DS MB T{tháng}`: cộng dồn **dạng công thức** `=a+b+c`, không ghi đè thành số.
7. Bảng mã là **hằng số JSON** cho mọi HKD/đại lý, không lưu DB.
8. Bỏ cột K `Người đi tiền` ở tab `MB`.
9. Chuyển tiền **không** cộng vào `DS MB` (DS MB chỉ lấy từ bill kết toán, tránh tính hai lần).

Ví dụ chốt: Lập gửi ảnh chuyển 29.274.000, tin nhắn `TK01`, ngày 10/10 → HKD Thiên Kim GV, đại lý Chương (tid1), người đi tiền Lập → tab `thu chi 1010`, khối `Chương`, chèn hàng 31, ô **J31** = `29274000`, `J33` (TOTAL) = `=SUM(J23:J32)`.

---

## 2. Hiện trạng và root cause

### 2.1 Ảnh nào cũng tạo transaction

Luồng cũ: `UpdateReceiver` → `DownloadTelegramAttachmentJob` → `AnalyzeBillImageJob` → `BuildTransactionJob` → `Transactions::Builder`.

- Chỉ có **một** cách nhận ra người đi tiền: `Remitters::Resolver` theo Telegram ID/username. Trên prod các Remitter được seed **chưa có ID nào**, nên không ai được nhận ra.
- Không có tín hiệu nào khác (mã trong tin nhắn, loại chứng từ sau OCR) để tách ảnh chuyển khoản ra khỏi luồng kết toán.
- `Transactions::Builder` dựng transaction cho mọi chứng từ của ảnh đơn (`transfer`, `unknown`, bill con chưa chắc), nên ảnh chuyển khoản và ảnh rác thành transaction "Cần kiểm tra" không phân tích được. Bản vá tạm (commit cờ `remitter_features_enabled`) chỉ bỏ qua các ảnh này **khi cờ tắt**; muốn xử lý đi tiền thì phải bật cờ, và ảnh rác lại tạo transaction.

**Root cause:** việc phân loại phụ thuộc hoàn toàn vào cấu hình Telegram ID của Remitter; không có model riêng cho lệnh đi tiền; và quy tắc "ảnh đơn chỉ bill kết toán mới tạo transaction" lại bị gắn vào cờ tính năng.

### 2.2 Báo cáo `thu chi` sai nguồn

- Code cũ ghi `thu chi` **từ transaction**, lấy người đi tiền = người gửi bill kết toán. Bill kết toán do đại lý gửi nên gần như không bao giờ có người đi tiền → `thu chi` không được ghi.
- Ghi vào "ô trống đầu tiên" của khối: khối đầy thì báo `rd_block_full`, không tự giãn; hàng đệm sát `TOTAL` bị né vì không chắc `SUM` có phủ.

### 2.3 `DS MB` mất công thức

`HelloSmcWriter#increment_daily` đọc ô bằng `UNFORMATTED_VALUE` rồi ghi `cũ + mới` dạng **số**. Ô đang là công thức sẽ bị thay bằng số; không còn vết từng bill.

---

## 3. Mục tiêu và ngoài phạm vi

**Mục tiêu:** phân loại đúng hai loại ảnh; lệnh đi tiền có vòng đời riêng (đọc, duyệt, ghi sheet); `thu chi` ghi từ lệnh đi tiền bằng cách chèn hàng; `DS MB` giữ công thức.

**Ngoài phạm vi:**
- Không đổi OCR, phí, duyệt, album của luồng kết toán (trừ quy tắc ảnh đơn ở §4.10).
- Không tự tạo tab ngày `thu chi`; không tự thêm người đi tiền vào bảng tổng hợp cuối tab (`TOTAL AMOUNT`, `REMAINING BALANCE`).
- Không tự xoá hàng trên sheet khi lệnh bị từ chối sau khi đã ghi.

---

## 4. Giải pháp

### 4.1 Tổng quan luồng

```
Telegram update (ảnh)
  │
  ├─ cờ bật && UpdateReceiver#transfer_photo?  ── có ──► RemitterTransfer(processing)
  │     (Remitter / mã trong tin nhắn /
  │      album đã là đi tiền; cờ tắt → luôn "không")
  │                                                       → Download → OCR
  │                                                       → BuildRemitterTransferJob
  │                                                       → RemitterTransfers::Builder
  │                                                           ├─ approved → WriteRemitterReportJob
  │                                                           │              → RemitterReportWriter (thu chi)
  │                                                           └─ needs_review → admin "Chuyển tiền"
  │
  └─ không ──► luồng kết toán: Download → OCR → AnalyzeBillImageJob#build_or_finalize
                    ├─ ảnh đơn, OCR thấy transfer, không settlement, chưa có transaction
                    │     → Classifier.adopt! → luồng đi tiền (như trên)
                    ├─ album → FinalizeBillAlbumJob (như cũ)
                    └─ còn lại → BuildTransactionJob → HelloSmcWriter (DS MB công thức + MB)
```

### 4.2 Phân loại (`RemitterTransfers::Classifier`)

| Thời điểm | Dấu hiệu là "đi tiền" |
|---|---|
| Nhận tin | Người gửi là Remitter **active** (`telegram_user_id`, rồi `telegram_username` không phân biệt hoa thường) |
| Nhận tin | Người gửi chưa khai: caption có một mã trong bảng §4.3 **đứng riêng** (dò **strict**, §4.4) |
| Nhận tin | Ảnh cùng `media_group_id` với một ảnh đã là đi tiền (Telegram chỉ gắn caption vào ảnh đầu album) |
| Sau OCR | Ảnh **đơn** (không album), **chưa có transaction**, chứng từ có `transfer` và không có `settlement` |
| Sau OCR (trả về kết toán) | Lệnh còn `processing` (vào luồng đi tiền nhờ người gửi **hoặc** nhờ mã) mà OCR ra `settlement` và không có `transfer` → lệnh `rejected` (`settlement_photo`), ảnh quay lại luồng transaction. OCR ra `unknown` / không chắc → giữ đi tiền (review) |

Quy tắc phụ:
- Nhóm Telegram phải đang **active**; nhóm chưa active thì ảnh chỉ được lưu (như ảnh kết toán).
- Cờ `remitter_features_enabled` (Cài đặt → Telegram) tắt → **không có luồng đi tiền**: mọi ảnh (kể cả của Remitter, caption có mã) đi luồng kết toán thường. Sau OCR: bill kết toán → transaction (remitter gửi bill kết toán vẫn không mất); ảnh chuyển khoản → tin nhắn `ignored`, không lệnh, không transaction. Ảnh của Remitter **không bao giờ gom album** (cờ bật hay tắt): cờ tắt thì gửi nhiều hình = nhiều ảnh đơn, ảnh nào không phải bill kết toán thì bỏ qua; cờ bật thì nhiều hình = nhiều lệnh đi tiền.
- Ảnh đi tiền không đi qua `BillAlbums::Collector`: mỗi ảnh một lệnh.
- Album của đại lý (bill con + tổng kết `settlement`/`transfer`) không bị phân loại lại.
- Ảnh đã có transaction (chạy lại OCR) giữ luồng kết toán.
- Remitter đã khai gửi bill kết toán: AI (OCR `document_type`) nhận ra `settlement` → tạo transaction như đại lý gửi; lệnh đi tiền giữ lại ở trạng thái `rejected` để đối chiếu.

### 4.3 Bảng mã chuyển tiền

Mã là một trường của từng dòng đại lý (`merchant_dealers.transfer_code`), đặt ở trang sửa HKD, mục Đại lý, ô **Mã chuyển tiền**. Bảng dưới là bộ mã khởi tạo (`Workbook::Seed::TRANSFER_CODES`, và migration `AddTransferCodeToMerchantDealers` đã chép từ file JSON cũ vào DB). Quy ước **tiền tố HKD + số TID**:

| Tiền tố | HKD (`hkd`) | Mã |
|---|---|---|
| `TK` | Thiên Kim GV (`001`) | TK01 Chương · TK02 Sơn · TK03 Hải |
| `GT` | Gat Tan Day Coffe (`GTD001`) | GT01 Cường Duyên · GT02 Trân · GT03 Thọ |
| `CH` | Cherry Coffee (`CHERRY001`) | CH01 Nghĩa Nghiệp · CH02 Cường Duyên · CH03 Trân |
| `ML` | HKD AS CAFE-CAFE MILO (`MILO001`) | ML127 · ML128 · ML129 (Chị Huệ) |
| `CF` | HKD AS CAFE-CAFE 96 (`AS96001`) | CF01 Phùng Cường · CF02 Anh Hiếu |
| `AS` | HKD AS CAFE (`ASCAFE001`) | AS01 Anh Hải · AS02 Anh Hùng · AS03 Chị Hồng |
| `NC` | HKD NCT (`NCT001`) | NC01 Chị Mến · NC02 Anh Hải · NC03 Nghiệp |
| `NM` | HKD NCT MBV (`NCTMBV001`) | NM01 Sơn · NM02 Anh Thọ · NM03 Tuân |

- Mã → `merchant_dealers` active theo (HKD, `tid`). HKD tra theo `match_code` của seed trước (prod có thể còn `002 CHERRY COFFE`, `099`), rồi `code`.
- Mã (`MerchantDealer`): bỏ khoảng trắng, viết hoa, dạng `[A-Z]+\d+`, **không trùng** với mã khác (không phân biệt hoa thường, kể cả dòng đang tắt); để trống nếu đại lý không nhận chuyển tiền. Đổi mã có hiệu lực ngay, không cần deploy.
- Mã của đại lý đang tắt vẫn được nhận ra và báo `code_dealer_inactive`.
- Seed chỉ điền mã còn trống, không ghi đè mã khách đã sửa.

### 4.4 Dò mã trong tin nhắn (`RemitterTransfers::CodeMatcher`)

1. Bỏ dấu, viết hoa, mỗi cụm ký tự không phải `A-Z0-9` thành **một dấu cách**: `"Zalo TK01 29.274.000"` → `"ZALO TK01 29 274 000"`.
2. Với mỗi mã `LETTERS+DIGITS`, khớp `/LETTERS ?DIGITS(?!\d)/`: cho phép một dấu cách giữa chữ và số (`tk 01`, `TK-01`), **không** cho số đứng ngay sau (`TK010`, `TK0129274000`). Trước mã có thể là gì cũng được (`ZALOTK01`, `abcTK01`).
3. Mã nằm trong mã khác cùng khớp → giữ mã dài hơn.
4. Còn > 1 mã → `code_ambiguous`; không có → `code_missing`.
5. **Strict** (`strict: true`) chỉ dùng khi quyết định ảnh của **người gửi chưa khai** có phải đi tiền lúc nhận tin: mã không được dính chữ/số trước hoặc sau (`/(?<![A-Z0-9])LETTERS ?DIGITS(?![A-Z0-9])/`). `"Bích 01"` → không phải mã, bill kết toán của đại lý không bị kéo sang luồng đi tiền. Đọc mã của lệnh (Builder) vẫn **loose** như đã chốt. Ảnh chuyển khoản của người lạ có mã dính (`ZALOTK01`) vẫn thành lệnh nhờ phân loại sau OCR.

### 4.5 Dữ liệu: bảng `remitter_transfers`

Ngoài caption, OCR đọc nguyên văn `transfer_memo` (nội dung chuyển khoản trên ảnh) và
`transfer_memo_confidence`. Khi caption không có mã, Builder dò mã đứng riêng trong memo:
`As02` / `AS 002` khớp mã cấu hình `AS2`, nhưng `AS20` là mã khác. Nguồn được lưu là `image`.
Mã trong caption và ảnh khác nhau → `code_conflict`; nhiều mã → `code_ambiguous`; mã OCR
chưa đủ tin cậy → `code_low_confidence`; hai model không thống nhất → `code_ocr_disagreement`.
Các trường hợp này giữ ở hàng đợi kiểm tra. Không dùng tên người nhận, số tài khoản hay mã tham chiếu ngân hàng để đoán mã.
Retry kết quả OCR cũ chưa từng đọc memo sẽ yêu cầu đọc lại trong ngân sách OCR hiện có;
kết quả mới đã có trường memo nhưng null không tự gây các lượt đọc lặp lại.

| Cột | Kiểu | Ghi chú |
|---|---|---|
| `telegram_message_id` | FK, unique, not null | Một tin nhắn = một lệnh |
| `bill_image_id` | FK, unique | Ảnh (có thể là bản ghi duplicate) |
| `remitter_id` | FK, **null được** | Null khi người gửi chưa khai, review chọn |
| `merchant_id`, `merchant_dealer_id` | FK | Từ mã |
| `transfer_code`, `code_source` | string | `caption` / `image` / `manual` |
| `amount_vnd`, `amount_confidence` | bigint, decimal(5,4) | Check `amount_vnd > 0` |
| `transferred_at` | datetime, not null | `sent_at` của tin nhắn → chọn tab ngày |
| `status` | string | `processing`, `needs_review`, `approved`, `rejected`, `failed` (check constraint) |
| `review_reasons` | string[] | §4.7 |
| `reviewed_by_id`, `reviewed_at` | | Người quyết định |
| `rd_sheet`, `rd_row`, `rd_cell`, `written_at` | | Kết quả ghi sheet |
| `metadata` | jsonb | `write_issue`, `write_sheet`, `total_fixed`, `total_unparsed`, `reconciled`, `caption_edited_after_write` |
| `lock_version` | integer | Optimistic lock cho form duyệt |

Migration `20261011230000_create_remitter_transfers` (reversible, `change`).

### 4.6 Đánh giá lệnh (`RemitterTransfers::Builder`)

Chạy sau OCR, khi tải ảnh lỗi/ảnh trùng, và khi caption bị sửa (chưa ghi sheet). Bỏ qua nếu đã ghi sheet, đã có người quyết định, đã từ chối, hoặc ảnh còn đang OCR.

| Bước | Quy tắc |
|---|---|
| Ảnh | Không có ảnh → `failed` (`image_missing`); OCR lỗi → `failed` (`ocr_failed`) |
| Số tiền | Ưu tiên chứng từ `transfer`, không có thì mọi chứng từ có số tiền. Không có → `amount_missing`; nhiều số khác nhau → `amount_ambiguous`; độ tin cậy < `ocr_auto_approve_threshold` (0.92) và chưa được model thứ hai xác nhận → `amount_low_confidence` |
| Mã | §4.4; mã đúng nhưng dòng đại lý tắt/không có → `code_dealer_inactive` |
| Người đi tiền | Null → `remitter_unknown`; tắt → `remitter_inactive` |
| Trùng | Ảnh trùng (sha256/`file_unique_id`) hoặc cùng người đi tiền + mã + số tiền trong `duplicate_window_minutes` → `possible_duplicate` |
| Kết quả | Không lý do → `approved`, enqueue `WriteRemitterReportJob` sau commit; có lý do → `needs_review` |

Ngày giờ, người nhận, loại chứng từ trên biên lai **không** ảnh hưởng.

### 4.7 Duyệt tay (`RemitterTransfers::Reviewer`, admin "Chuyển tiền")

- Danh sách theo tab: Cần kiểm tra / Đã duyệt chưa ghi sheet / Đã ghi sheet / Đang xử lý / Từ chối-lỗi.
- Trang chi tiết: ảnh (zoom/xoay), tin nhắn, số tiền + độ tin cậy, mã, HKD, đại lý, ô đã ghi.
- **Duyệt**: chọn mã (danh sách "TK01 · Thiên Kim GV · Chương"), sửa số tiền, chọn người đi tiền. Số tiền chỉ nhận VND nguyên: `29274000`, `29.274.000`, `29,274,000 ₫`; `29.5`, `-100`, `29tr` bị từ chối (không đoán). Thiếu mã hợp lệ/số tiền/người đi tiền → báo lỗi. `code_source = manual` khi đổi mã. Enqueue ghi sheet.
- **Từ chối**: không ghi sheet. Lệnh đã từ chối (chưa ghi sheet) vẫn có thể duyệt lại.
- Lệnh đang `processing` (chưa OCR xong) không hiện form.
- Đã ghi sheet → không sửa/từ chối được (phải sửa tay trên sheet). Lệnh duyệt nhưng ghi lỗi (`rd_sheet_missing`…) có nút **Ghi lại**.
- Quyền: `admin` + `operator` quản lý; `viewer` chỉ xem.
- Audit: `remitter_transfer.evaluated / approved / rejected / written`.

### 4.8 Ghi tab `thu chi` (`Workbook::RemitterReportWriter`)

1. Chỉ ghi lệnh `approved` có số tiền, đại lý, người đi tiền; chưa `written_at`.
2. Khoá advisory theo spreadsheet (`Workbook::SheetLock`, dùng chung với `HelloSmcWriter`).
3. Tab `thu chi #{day}#{month}` theo `transferred_at` (giờ VN). Không có → `rd_sheet_missing`.
4. Đọc `A:AZ`, cắt trước vùng sổ quỹ (`SP in`, `MB in`, `TOTAL AMOUNT`).
5. Khối = nhãn đại lý khớp `merchant_dealer.rd_agent_label` (bỏ kênh, dấu, hoa thường). Cột = tiêu đề hàng 2 khớp `remitter.excel_key`; chưa có cột → chèn cột cho mọi khối (giữ hành vi cũ). Tìm hàng `TOTAL`.
6. **Idempotent:** đọc note của cột người đi tiền trong khối; có `RT<id>` → đã ghi, chỉ cập nhật DB.
7. **Chèn hàng:** vị trí `max(TOTAL − 1, nhãn + 1)` (0-based) = ngay trên hàng dữ liệu cuối. Một `spreadsheets.batchUpdate` gồm:
   - `insertDimension` ROWS (cả hàng sheet, `inheritFromBefore`),
   - `updateCells` ghi số tiền (`numberValue`) + note `RT<id> +<số tiền>`.
   Chèn cả hàng để các khối cùng dải (Hồng / Chị Huệ / PCuong…) thẳng hàng và sổ quỹ dịch nguyên khối. Chèn trong vùng `SUM` nên Sheets tự giãn `=SUM(J23:J31)` → `=SUM(J23:J32)` và giãn ô nhãn đang merge.
8. **Cập nhật TOTAL:** đọc hàng `TOTAL` mới bằng `FORMULA`. Ô `=SUM(Xa:Xb)` (cùng cột) mà `b` = hàng ngay trên hàng mới → sửa thành `b+1`. Công thức khác dạng → ghi `total_unparsed`, không sửa.
9. Ghi `written_at`, `rd_sheet`, `rd_row`, `rd_cell`, audit.

Cột người đi tiền tìm theo tiêu đề: tab `thu chi 1010` (có `LOI`) → `LẬP` = J; tab `thu chi 1110` → `LẬP` = I.

### 4.9 `DS MB T{tháng}` dạng công thức (`HelloSmcWriter`, luồng transaction)

- Đọc ô ngày × đại lý bằng `FORMULA`, ghi bằng `USER_ENTERED`:

| Ô hiện tại | Ghi |
|---|---|
| trống | `=n` |
| số nguyên `x` | `=x+n` |
| `=a+b…` (chỉ số và `+`/`-`) | `=a+b…+n` |
| số gõ dạng chữ (`354.367.000`, `354,367,000`) | `=354367000+n` |
| chữ / công thức khác | không đụng ô; bill ghi vào **Bill vô chủ** với `ds_cell_not_numeric` (như mọi ô DS MB không tìm được), MB không ghi |

- Tạo tháng mới (nhân bản tab tháng trước): xoá cả số lẫn công thức cộng dồn ở các cột số tiền; công thức `Tổng cộng` (`=sum(...)`) giữ nguyên.
- Idempotent giữ như cũ: marker `TX<id>` ở MB cột L + `workbook_entries`.
- Transaction không còn ghi `thu chi`; cột K tab `MB` để trống; `Workbook::Resolver` không còn tra remitter.

### 4.10 Ảnh đơn: chỉ bill kết toán tạo transaction (`Transactions::Builder`)

Áp dụng **bất kể cờ** `remitter_features_enabled`, **chỉ cho ảnh Telegram**. Ảnh tải tay trong admin (`manual_upload`) do người chọn nên luôn được dựng transaction như cũ.

| Ảnh | Kết quả |
|---|---|
| Ảnh đơn, chứng từ `settlement` | Transaction như cũ |
| Ảnh đơn, `transfer` | Không transaction (đã sang `RemitterTransfer` ở §4.2) |
| Ảnh đơn, `unknown` / bill con (kể cả chưa chắc) | Không transaction, tin nhắn `processed` |
| Ảnh đơn mà **OCR có sự cố**: `malformed_primary_extraction`, `primary_output_truncated`, `primary_refused`, `validation_budget_exhausted`, `validator_failed` (dù đọc ra `unknown`) | Vẫn tạo transaction `needs_review` như cũ, để người duyệt thấy |
| OCR lỗi hẳn (`ocr_failed`) | Vẫn tạo transaction `failed` |
| Album | Giữ nguyên (bill con là bằng chứng, tổng kết `settlement`/`transfer` tạo 1 transaction review) |

Kèm theo, `BillVision::ValidationPolicy`: `amount_unreadable` / `transaction_date_unreadable` xét cho `settlement` và `transfer`; `merchant_unreadable` / `transaction_time_unreadable` **chỉ xét `settlement`** (chuyển khoản không in HKD/terminal, giờ không dùng). Trước đó mọi ảnh chuyển khoản đều gọi thêm model kiểm chứng.

### 4.11 Job, retry, dọn dữ liệu

| Thành phần | Hành vi |
|---|---|
| `BuildRemitterTransferJob` | Gọi Builder; retry deadlock |
| `WriteRemitterReportJob` (queue `exports`) | Retry giống `WriteHelloSmcWorkbookJob`: lock bận 200 lần, 429/5xx/mạng 12 lần, discard khi thiếu spreadsheet id |
| `RetryWorkbookWritesJob` | Quét thêm lệnh `approved` chưa ghi quá 15 phút, **trừ** lệnh có `metadata.write_issue` (không đặt được vào sheet: chờ người sửa sheet rồi bấm "Ghi lại", không đọc lại sheet mỗi lượt) |
| `DownloadTelegramAttachmentJob` | Ảnh lỗi/không có/trùng của lệnh đi tiền → Builder ngay (không treo `processing`) |
| `hellosmc:purge_transaction_data` | Xoá thêm `remitter_transfers` |

---

## 5. Phương án đã cân nhắc

| Vấn đề | Phương án | Chọn | Lý do |
|---|---|---|---|
| Lưu bảng mã | DB (cột `transfer_code` ở `merchant_dealers`) / JSON hằng số | JSON | Người dùng yêu cầu; mã ít thay đổi, review qua git |
| Nguồn mã | Nội dung chuyển khoản trên biên lai (OCR) / tin nhắn Telegram | Tin nhắn | Ảnh mẫu thu gọn "Chi tiết giao dịch" nên không có nội dung; người dùng chốt chỉ cần số tiền |
| Ô `thu chi` | Cộng dồn một ô / ô trống đầu tiên / chèn hàng | Chèn hàng | Người dùng chốt; không bao giờ đầy khối, mỗi lệnh một dòng đối chiếu được |
| Kiểu chèn | Chỉ các cột của khối (`insertRange`) / cả hàng (`insertDimension`) | Cả hàng | Giữ các khối cùng dải thẳng hàng, sổ quỹ không vỡ |
| Chống ghi trùng | Marker trong ô / note ô / chỉ dựa DB | Note ô | Không làm bẩn giá trị; nằm cùng request với insert |
| Chuyển tiền ghi DS MB | Có / không | Không | Bill kết toán đã ghi DS MB; ghi thêm là tính hai lần |
| Phân loại | Chỉ theo người gửi / thêm mã + loại chứng từ | Ba tín hiệu | Prod chưa khai Telegram ID; cần chặn transaction ngay cả khi cấu hình thiếu |

---

## 6. Test case

Cột "File" là nơi test được viết. Suite (kể cả test của §7.4) xanh: **679 examples, 0 failures** (12/10/2026).

### 6.1 Bảng mã và dò mã

| ID | Tình huống | Kỳ vọng | File |
|---|---|---|---|
| C1 | Nạp bảng | Mọi mã đúng dạng, không trùng (HKD, tid) | `remitter_transfers/codes_spec.rb` |
| C2 | Sau `Workbook::Seed` | Mọi mã trỏ đúng một `merchant_dealers` active | idem |
| C3 | `tk01` | Thiên Kim GV, tid1, Chương | idem |
| C4 | HKD còn code cũ `002 CHERRY COFFE` | Vẫn tra ra Cherry | idem |
| C5 | Mã lạ / dòng đại lý tắt | nil | idem |
| C6 | Trang HKD | Liệt kê mã của dòng đại lý (`NM03`), **0 query** mỗi dòng | idem |
| M1 | `"...qua Zalo TK01"`, `"ZALOTK01"`, `"abc tk01"`, `"tk 01"`, `"TK-01 nhé"` | `TK01` | `remitter_transfers/code_matcher_spec.rb` |
| M2 | `"TK01 29.274.000"`, `"tk01-29274000"`, `"TK01: 29tr"` | `TK01` | idem |
| M3 | Có dấu tiếng Việt | Bỏ dấu, vẫn khớp | idem |
| M4 | `"TK010"` | `code_missing` | idem |
| M5 | `"ml127"` | `ML127` | idem |
| M6 | `TK01` và `XTK01` cùng khớp | `XTK01` | idem |
| M7 | `"TK01 GT02"` | `code_ambiguous` | idem |
| M8 | Không có mã / nil | `code_missing` | idem |
| M9 | `"TK01."`, `"TK01,"`, `"TK01:"`, `"TK01A"` (lỡ tay thêm 1 ký tự) | `TK01` | idem |
| M10 | Strict: `"chuyen TK01"`, `"TK01"`, `"tk 01"`, `"TK01: 29tr"`, `"TK-01 nhé"` | `TK01` | idem |
| M11 | Strict: `"Bích 01"`, `"...ZALOTK01"`, `"TK01A"` | `code_missing` | idem |
| M12 | Loose (mặc định): `"Bích 01"` | `CH01` (chốt hành vi loose) | idem |

### 6.2 Phân loại và nhận tin

| ID | Tình huống | Kỳ vọng | File |
|---|---|---|---|
| R1 | Cờ bật, người gửi khớp `user_id` | `:queued_remitter_transfer`, tạo lệnh `processing`, enqueue tải ảnh | `remitter_transfers/receiving_spec.rb` |
| R2 | Khớp `username` khác hoa thường | Luồng đi tiền | idem |
| R3 | Người lạ gửi caption `TK01` | Luồng đi tiền, `remitter` = nil | idem |
| R4 | Ảnh thứ hai của album không caption | Luồng đi tiền nhờ ảnh đầu | idem |
| R5 | Remitter tắt / người khác, caption `MB` | Luồng kết toán | idem |
| R6 | Cờ tắt, ảnh của Remitter / caption `TK01` | `:queued` (luồng thường, tải ảnh + OCR), không tạo lệnh | idem, `remitter_feature_flag_spec.rb` |
| R11 | Cờ tắt, Remitter gửi album 2 ảnh | Cả hai `:queued`, không tạo `BillAlbum` (mỗi ảnh là ảnh đơn) | `remitter_feature_flag_spec.rb` |
| R12 | Cờ tắt, đại lý gửi album | Vẫn gom `BillAlbum` | idem |
| R7 | Album của người đi tiền | Không tạo `BillAlbum` | `receiving_spec.rb` |
| R8 | Sửa caption trước khi ghi sheet | Builder chạy lại | idem |
| R9 | Sửa caption sau khi ghi sheet | Chỉ đánh dấu `caption_edited_after_write` | idem |
| A1 | Ảnh đơn OCR ra `transfer`, người lạ | Tạo lệnh (remitter nil), không `BuildTransactionJob` | idem |
| A2 | Ảnh đơn OCR ra `settlement` | `BuildTransactionJob`, không lệnh | idem |
| A3 | Ảnh `transfer` trong album đại lý | `FinalizeBillAlbumJob`, không lệnh | idem |
| A4 | Cờ tắt, ảnh `transfer` | Không lệnh, không transaction, tin nhắn `ignored` | idem |
| A5 | Ảnh đã gắn lệnh sau OCR | `BuildRemitterTransferJob` thay vì transaction | idem |
| A6 | Ảnh trùng của ảnh gốc đã có transaction | Không bị nhận thành đi tiền | idem |
| R10 | Người lạ gửi caption `"Bích 01"` | `:queued` (luồng kết toán), không tạo lệnh | idem |
| A7 | Lệnh chỉ nhờ mã (remitter nil), OCR ra `settlement` | Lệnh `rejected` (`settlement_photo`), `BuildTransactionJob` | idem |
| A8 | Lệnh của Remitter đã khai, OCR ra `settlement` | Lệnh `rejected` (`settlement_photo`), `BuildTransactionJob` | idem |
| A9 | Lệnh của Remitter, OCR ra `unknown` | Giữ đi tiền, `BuildRemitterTransferJob` | idem |
| A10 | Lệnh đã đánh giá (`approved`), OCR chạy lại ra `settlement` | Không đổi, không transaction | idem |
| A11 | Lệnh đã trả về (`rejected`/`settlement_photo`), transaction được "Chạy lại OCR" | `BuildTransactionJob` dựng lại transaction, không đụng lệnh | idem |
| A12 | Lệnh `failed` (OCR lỗi), OCR thử lại thành công ra `settlement` | Lệnh `rejected` (`settlement_photo`), `BuildTransactionJob` | idem |
| A13 | Lệnh bị người từ chối (lý do khác), OCR chạy lại ra `settlement` | Không transaction | idem |

### 6.3 Đánh giá lệnh

| ID | Tình huống | Kỳ vọng | File |
|---|---|---|---|
| B1 | 29.274.000, 0.96, `TK01`, Lập | `approved`, Chương/tid1, enqueue ghi, 0 transaction | `remitter_transfers/builder_spec.rb` |
| B2 | Độ tin cậy 0.90 | `needs_review` (`amount_low_confidence`) | idem |
| B3 | Loại chứng từ `unknown`, không ngày | Vẫn `approved` | idem |
| B4 | Không mã / hai mã / mã của dòng tắt | `code_missing` / `code_ambiguous` / `code_dealer_inactive` | idem |
| B5 | Người gửi chưa khai | `remitter_unknown` | idem |
| B6 | Không đọc được số tiền | `amount_missing` | idem |
| B7 | Cùng người, mã, số tiền cách 2 phút | Lệnh sau `possible_duplicate` | idem |
| B8 | OCR lỗi | `failed` | idem |
| B9 | Ảnh đang OCR | Giữ `processing` | idem |
| B10 | Đã ghi sheet | Không đổi, không enqueue | idem |

### 6.4 Ghi `thu chi`

| ID | Tình huống | Kỳ vọng | File |
|---|---|---|---|
| W1 | Ví dụ chốt (tab `thu chi 1010`, khối Chương 23–31, TOTAL 32) | J31 = 29274000, note `RT<id> +29274000`, J33 = `=SUM(J23:J32)`, khối bên (A33/B33) và `SP in` dịch theo, `rd_cell` = J31 | `workbook/remitter_report_writer_spec.rb` |
| W2 | Lệnh thứ hai cùng ngày | Thêm J32, J34 = `=SUM(J23:J33)` | idem |
| W3 | Tab không có cột `LOI` | Ghi I31 | idem |
| W4 | Gửi 23:50 ngày 11/10 | Ghi tab `thu chi 1110` | idem |
| W5 | Khối chỉ có hàng nhãn (SUM không tự giãn) | Hàng mới dưới nhãn, TOTAL sửa thành `=SUM(J23:J24)` | idem |
| W6 | TOTAL không phải `SUM` | Không sửa, `total_unparsed` | idem |
| W7 | Chạy lại sau khi sheet đã ghi nhưng DB chưa lưu | `:already_written`, không thêm hàng | idem |
| W8 | Không có tab / khối | `rd_sheet_missing` / `rd_agent_missing`, lưu `write_issue` | idem |
| W9 | Chưa duyệt / đã ghi | `:skipped_not_approved` / `:already_written` | idem |
| W10 | Người đi tiền mới | Chèn cột ở mọi khối rồi chèn hàng | idem |

### 6.5 DS MB và transaction

| ID | Tình huống | Kỳ vọng | File |
|---|---|---|---|
| D1 | Ô 354.367.000 + bill 486.000 | `=354367000+486000`, một `batchUpdate` | `workbook/hello_smc_writer_spec.rb` |
| D2 | Ô trống / có công thức cộng dồn / số 1000 | `=486000` / nối thêm / `=1000+486000` | idem |
| D3 | Đọc ô | `value_render_option: "FORMULA"` | idem |
| D4 | Ô chữ (`ghi chú`) | Ô giữ nguyên, MB không ghi, hàng **Bill vô chủ**, entry `unidentified` + `ds_cell_not_numeric` | idem |
| D9 | Ô số gõ dạng chữ `354.367.000` | `=354367000+486000` | idem |
| D10 | Ô công thức khác (`=SUM(C2:D2)`) | Không đụng ô, `ds_cell_not_numeric` | idem |
| D5 | Hai bill liên tiếp | `=354367000+100000+200000`, giá trị tính đúng | idem |
| D6 | Tạo tháng mới | Xoá công thức cộng dồn, giữ `=sum(...)` | idem |
| D7 | Transaction có Remitter là người gửi | MB cột K trống, không đọc tab `thu chi`, payload không có `remitter_id` | idem |
| D8 | `Workbook::Resolver` | Không còn trả remitter | `workbook/resolver_spec.rb` |
| S1 | Ảnh đơn `settlement` | 1 transaction | `transactions/single_photo_settlement_only_spec.rb` |
| S2 | Cờ bật, ảnh đơn `transfer` / `unknown` / bill con | Không transaction | idem |
| S3 | OCR lỗi | Transaction `failed` | idem |
| S4 | Album: tổng kết `settlement` hoặc `transfer` | Transaction `album_total_review` | `remitter_feature_flag_spec.rb` |
| S5 | Ảnh đơn `unknown` mang lý do OCR có sự cố (5 lý do) | Transaction `needs_review` kèm lý do đó | `transactions/single_photo_settlement_only_spec.rb`; 4 ca trong `bill_vision/pipeline_spec.rb` (malformed, truncated, refused, budget) |
| S6 | Ảnh tải tay (`manual_upload`) đọc ra `unknown` | Vẫn tạo transaction `needs_review` | `transactions/single_photo_settlement_only_spec.rb` |
| V1 | Chứng từ `transfer` không HKD, không giờ | Không lý do kiểm chứng, không gọi validator | `bill_vision/validation_policy_spec.rb` |
| V2 | Chứng từ `transfer` không số tiền | `amount_unreadable` | idem |
| V3 | Chứng từ `settlement` không HKD, không giờ | `merchant_unreadable`, `transaction_time_unreadable` | idem |
| J1 | Lệnh `approved` mất job ghi | `RetryWorkbookWritesJob` enqueue lại | `jobs/retry_workbook_writes_job_spec.rb` |
| J2 | Lệnh đã ghi / có `write_issue` / chưa duyệt | Không enqueue | idem |

### 6.6 Admin

| ID | Tình huống | Kỳ vọng | File |
|---|---|---|---|
| U1 | Danh sách | Lệnh cần kiểm tra + lý do | `requests/admin/remitter_transfers_spec.rb` |
| U2 | Chi tiết | Ảnh, tin nhắn, danh sách mã | idem |
| U3 | Duyệt + sửa mã/số tiền | `approved`, `code_source = manual`, enqueue ghi, audit | idem |
| U4 | Duyệt thiếu mã | Báo lỗi, giữ `needs_review` | idem |
| U5 | Từ chối | `rejected`, không ghi | idem |
| U9 | Số tiền `29.5` / `-100` / `29tr` | Báo "Số tiền không hợp lệ", giữ `needs_review` | idem |
| U6 | Lệnh đã ghi | Không đổi được | idem |
| U7 | Ghi lại | Enqueue ghi | idem |
| U8 | Viewer | Xem được, sửa → 403 | idem |

### 6.7 Kiểm thử tay trên staging/prod (sau deploy)

1. Khai Telegram ID cho Lập; bật cờ; Lập gửi ảnh chuyển khoản + `TK01` → lệnh tự duyệt, tab `thu chi {hôm nay}` có hàng mới trong khối Chương, cột LẬP, TOTAL đúng.
2. Người lạ gửi ảnh chuyển khoản không mã → lệnh "Cần kiểm tra" (`code_missing`, `remitter_unknown`), **không** có transaction.
3. Đại lý gửi bill kết toán → transaction như cũ; ô DS MB thành công thức.
4. Xoá tab ngày rồi duyệt lệnh → "Chưa có tab"; tạo tab, bấm Ghi lại → ghi được.

---

## 7. Review

### 7.1 Đã rà và sửa trong lúc review

| # | Vấn đề | Sửa |
|---|---|---|
| 1 | Dò mã bỏ hết khoảng trắng làm mã dính vào số tiền phía sau: `"TK01 29.274.000"` → `TK0129274000` → không khớp (rất hay gặp) | Giữ một dấu cách giữa các cụm, cho phép `LETTERS ?DIGITS`; thêm test M2 |
| 2 | `DS MB` đổi sang công thức nhưng bước tạo tháng mới chỉ xoá ô **số** → tháng mới sẽ giữ công thức tháng trước | `amount_cell?` xoá cả công thức cộng dồn; test D6 |
| 3 | Bảng `remitter_transfers` có FK tới `bill_images` / `telegram_messages` → `purge_transaction_data` (TRUNCATE không CASCADE) sẽ lỗi | Thêm bảng vào danh sách purge |
| 4 | Lệnh đi tiền có ảnh tải lỗi/ảnh trùng sẽ treo `processing` mãi | `DownloadTelegramAttachmentJob` gọi Builder ngay |
| 5 | Người lạ gửi mã → không có remitter, model cũ bắt buộc `remitter_id` | Cho phép null + lý do `remitter_unknown` |
| 6 | Chạy lại OCR ảnh đã có transaction có thể bị phân loại thành đi tiền, để transaction treo `processing` | `transfer_image?` loại ảnh đã có transaction |
| 7 | Reviewer dùng `break` trong transaction block (Rails 8 commit khi thoát sớm) | Đổi sang `raise ActiveRecord::Rollback` |
| 8 | Quy tắc "ảnh đơn chỉ bill kết toán tạo transaction" gắn với cờ: bật cờ để xử lý đi tiền thì ảnh rác lại tạo transaction | Tách khỏi cờ (§4.10), thêm test S1–S3 |

### 7.2 Review bên ngoài (12/10/2026) và kết quả chạy suite

Người dùng chạy suite: **22 fail** (18 do spec tạo trùng `excel_key` "LẬP" sau `Workbook::Seed`, 4 ở `pipeline_spec`).

| # | Nhận xét | Đánh giá | Xử lý |
|---|---|---|---|
| 1 | §4.10 nuốt ảnh OCR có sự cố (malformed/truncated/refused/budget) → biến mất khỏi review; 4 `pipeline_spec` fail | **Đồng ý, regression thật** | Giữ transaction review khi chứng từ mang lý do OCR có sự cố (`OCR_PROBLEM_REASONS`, thêm cả `validator_failed`); test S5 |
| 2 | 18 spec fail do trùng `excel_key` | Đồng ý | `builder_spec`, `admin/remitter_transfers_spec` dùng lại Lập do seed tạo. `remitter_report_writer_spec` không chạy seed nên không trùng `excel_key`; nếu file này còn fail thì cần output để xem nguyên nhân |
| 3 | N+1 ở trang HKD | Đồng ý hướng, **không đồng ý con số**: trang HKD chỉ hiện đại lý của **một** HKD (2–3 dòng × 23 mã × 1–2 query ≈ 50–140 query, không phải ~1000) | So mã trong bộ nhớ, 0 query mỗi dòng; test C6 |
| 4 | Retry lặp vô hạn với `rd_sheet_missing` | Đồng ý một phần: thiết kế cũ cố ý thử lại để tự ghi khi tab được tạo, chi phí 1–2 lượt đọc/10 phút; nhưng `rd_agent_missing` (lỗi cấu hình) thì không bao giờ tự hết | Bỏ qua lệnh có `write_issue` trong lưới an toàn; người dùng bấm "Ghi lại" sau khi sửa sheet; test J1–J2 |
| 5 | Ảnh trùng không xét transaction của ảnh gốc | Đồng ý (ảnh trùng hiện không OCR lại, nhưng rẻ để chặn) | Kiểm tra cả ảnh gốc; test A6 |
| 6 | `parse_amount` bỏ hết ký tự không phải số | Đồng ý | Chỉ nhận VND nguyên có phân cách hàng nghìn; test U9 |
| 7 | Mã khớp cả khi có chữ phía sau (`TK01A`) / dính chữ phía trước | Đã nằm trong rủi ro #1 và câu hỏi mở §10.1 | **Người dùng quyết: giữ loose** (chịu ký tự thừa như `TK01.`, `TK01A` để không bỏ sót khi lỡ tay). Chấp nhận rủi ro `"Bích 01"` → `CH01`; test M9 chốt hành vi |
| 8 | Gán `bill_image` ngầm qua `||=` | Đồng ý | Gán tường minh trong attributes |
| 9 | Tên biến 0-based/1-based ở `extend_totals` | Đồng ý | Đặt tên rõ `row_above_new`, `new_row_number` |
| 10 | `number_value` nên là Float | Đồng ý (vô hại) | `value.to_f` ở `GoogleSheetClient` |

### 7.3 Chưa kiểm chứng

- **Suite đã xanh: 658 examples, 0 failures** sau §7.2; **679 examples, 0 failures** sau §7.4 (gồm #7–#8).
- Hành vi thật của Google Sheets với `insertDimension` trong vùng merge + `SUM` (giãn range, giãn merge) đã giả lập trong `MemorySheet`, chưa thử trên sheet thật.
- Bố cục dòng của tab `thu chi` thật (nhãn hàng 23, TOTAL hàng 32) lấy từ file mẫu cũ; cột đã đối chiếu với Google Sheet thật (`thu chi 1010` có `LOI`, `thu chi 1110` không có).
- View ERB chưa render thử ngoài spec request.

### 7.4 Review senior (12/10/2026, sau khi suite xanh)

| # | Mức | Vấn đề | Sửa |
|---|---|---|---|
| 1 | **High** | Người lạ (đại lý) gửi bill **kết toán** kèm caption có chuỗi giống mã (`"Bích 01"` → `CH01`, `"lịch 02"` → `CH02`) bị kéo sang luồng đi tiền ngay lúc nhận tin → **mất transaction, DS MB thiếu tiền**. Rủi ro #1 cũ chỉ tính tới auto-approve của remitter, chưa tính chiều này | Lúc nhận tin, người lạ dùng dò **strict** (§4.4.5). Thêm lưới sau OCR: lệnh chỉ nhờ mã mà ảnh là `settlement` → `rejected` (`settlement_photo`), quay lại luồng transaction. Đọc mã vẫn loose như đã chốt. Test M10–M12, R10, A7–A8 |
| 2 | **High** | §4.10 áp cho cả ảnh **tải tay** trong admin: người dùng tải ảnh không phải kết toán thì ảnh "biến mất", không transaction, không báo | Chỉ áp cho ảnh Telegram; test S6 |
| 3 | **High** (test infra) | `after(:suite)` trong `rails_helper` xoá `tmp/storage` → xoá luôn `tmp/storage/.keep` đang được git theo dõi (mỗi lần chạy suite, `git status` báo file bị xoá; commit nhầm thì môi trường mới thiếu thư mục) | Chỉ xoá nội dung `tmp/storage/*`; đã tạo lại `.keep` |
| 4 | Medium (chi phí) | Mọi ảnh chuyển khoản đều thiếu HKD/giờ → `merchant_unreadable` + `transaction_time_unreadable` → **gọi thêm model kiểm chứng cho mỗi lệnh đi tiền** (gấp đôi chi phí OCR, chậm hơn) | Hai lý do đó chỉ xét `settlement`; test V1–V3 |
| 5 | Medium | Ô DS MB không cộng được (chữ, công thức khác) → bỏ DS MB nhưng vẫn ghi MB: báo cáo ngày thiếu tiền mà không ai thấy | Ghi vào **Bill vô chủ** (`ds_cell_not_numeric`) như ô không tìm thấy; số gõ dạng chữ `354.367.000` được cộng; test D4, D9, D10 |
| 6 | Low | `RetryWorkbookWritesJob` dùng toán tử jsonb `?` trong chuỗi SQL thô (dễ bị hiểu là placeholder bind) | Đổi sang `metadata->>'write_issue' IS NULL` |

Rà lại sau khi trả bill kết toán của remitter về transaction và bỏ gom album cho remitter:

| # | Mức | Vấn đề | Sửa |
|---|---|---|---|
| 7 | **High** | Transaction sinh từ lệnh đã trả về (`settlement_photo`) bấm "Chạy lại OCR" → job thấy tin nhắn còn gắn lệnh đi tiền → chạy Builder đi tiền (bỏ qua vì `rejected`) → transaction **treo `processing` mãi** | Lệnh `rejected` + `settlement_photo` coi như không có; test A11 |
| 8 | Medium | Ảnh OCR lỗi lần đầu (lệnh `failed`), lần thử lại đọc ra bill kết toán → vẫn ở luồng đi tiền, `needs_review` | Cho phép trả về cả lệnh `failed`; test A12 |

Đã rà và **không** thấy vấn đề: khoá advisory dùng chung cho hai writer (không deadlock vì mỗi job chỉ giữ một khoá); idempotency `RT<id>`/`TX<id>` khi batch đã áp mà DB chưa lưu; `lock_version` ở duyệt tay; enqueue sau commit; `raise ActiveRecord::Rollback` thay cho `break`; retry 429/5xx có backoff; trang HKD 0 query mỗi dòng.

---

## 8. Rủi ro và lưu ý

| # | Rủi ro | Mức | Giảm thiểu |
|---|---|---|---|
| 1 | **Mã trùng chữ trong tin nhắn:** cho phép dính chữ phía trước nên `"Bích 01"` → `BICH 01` khớp `CH01`; `"lịch 02"` khớp `CH02` | Thấp | **Đã chốt: giữ loose** khi đọc mã của lệnh; người lạ chỉ được nhận thành đi tiền khi mã đứng riêng (strict) + lưới sau OCR (§7.4 #1) |
| 2 | Chèn cả hàng thêm hàng trống vào các khối cùng dải | Thấp | Không đổi số liệu; giữ thẳng hàng và sổ quỹ |
| 3 | Khối bên cạnh có cấu trúc dòng khác (TOTAL lệch dòng) | Thấp | Sheets tự dịch tham chiếu; chỉ sửa TOTAL của dòng TOTAL khối mình |
| 4 | Người dùng xoá note `RT<id>` trước khi DB lưu → retry thêm hàng thứ hai | Rất thấp | Cửa sổ chỉ là giữa batchUpdate và lưu DB |
| 4b | Lệnh không đặt được vào sheet (`write_issue`) không tự thử lại | Thấp | Admin hiện cảnh báo đỏ + nút "Ghi lại"; tab "Đã duyệt, chưa ghi sheet" |
| 5 | Hạn mức Google Sheets (60 lượt đọc/phút): mỗi lệnh 4 lượt đọc (danh sách tab, đọc tab, note, hàng TOTAL) + 1–2 lượt ghi → trần ~15 lệnh/phút cho cả hệ thống, chung hạn mức với luồng transaction | Trung bình khi dồn dập | Khoá theo spreadsheet + retry 429 có backoff + lưới an toàn 15 phút |
| 6 | Người đang sửa tay đúng vùng lúc app chèn hàng | Thấp | Sheets xử lý chỉnh sửa đồng thời; hàng của app có note để nhận ra |
| 7 | Lệnh hợp lệ gửi trùng số tiền trong 10 phút → review | Thấp | Chấp nhận (an toàn hơn ghi đôi) |
| 8 | Chuyển tiền gửi sau nửa đêm cho ngày hôm trước vào tab ngày mới | Thấp | Theo yêu cầu (ngày gửi tin nhắn); sửa tay nếu cần |
| 9 | Ảnh chuyển khoản của **đại lý** (không phải người đi tiền) nay thành lệnh đi tiền thay vì transaction | Chấp nhận | Đúng yêu cầu "đi tiền không tạo transaction"; lệnh không có remitter sẽ review |
| 10 | Prod chưa khai Telegram ID của Remitter → mọi lệnh có mã nhưng `remitter_unknown` | Cao nếu quên | Bước deploy bắt buộc (§9) |
| 11 | Công thức DS MB dài dần | Thấp | Giới hạn 50.000 ký tự/ô ≈ 5.000 bill/ô/ngày |
| 12 | Sửa/từ chối lệnh đã ghi không tự rút khỏi sheet | Chấp nhận | Admin cảnh báo "sửa tay trên sheet" |
| 13 | Đổi bảng mã cần deploy | Chấp nhận | Theo yêu cầu (hằng số); spec C1–C2 bắt lỗi bảng |
| 14 | Bill kết toán thật bị OCR đọc thành `unknown` → bị bỏ qua, không hiện trong "Cần kiểm tra" | Trung bình | Theo yêu cầu ("ảnh khác thì bỏ qua"); OCR lỗi hẳn vẫn hiện; ảnh gốc vẫn lưu, chạy lại được |
| 15 | Album của **người lạ** (chưa khai ID) có mã ở caption ảnh đầu: webhook xử lý song song, ảnh sau có thể tới trước ảnh có caption → đi luồng album, tổng kết thành transaction | Thấp | Khai Telegram ID cho người đi tiền (khi đó phân loại theo người gửi, không phụ thuộc thứ tự) |
| 16 | Cờ tắt: mọi ảnh chuyển khoản của remitter đều được OCR (tốn phí OCR) để bắt bill kết toán | Thấp | Cờ tắt chỉ là trạng thái tạm; bật cờ để dùng luồng đi tiền |
| 16b | Remitter gửi đúng kiểu album đại lý (bill con + tổng kết) → không gom album, không đối chiếu tổng | Thấp | Remitter không gửi kiểu này; bill kết toán trong đó vẫn thành transaction |
| 17 | **Tên tab `thu chi {ngày}{tháng}` không phân biệt được** `1/11` và `11/1` (cùng `thu chi 111`), tương tự `1/12`–`11/2`, `2/11`–`21/1`… Nếu file giữ tab tháng cũ, lệnh sẽ ghi vào tab sai | Cao từ 1/11 nếu file chứa tab nhiều tháng | Cần chốt quy ước tên tab (vd. `thu chi 01/11`) hoặc mỗi tháng một file / xoá tab cũ; xem §10.4 |
| 18 | OCR đọc nhầm ảnh chuyển khoản của remitter thành `settlement` → thành transaction thay vì lệnh đi tiền | Thấp | Chuyển khoản không có số lô/TID nên transaction rơi vào "Cần kiểm tra", không mất; lệnh `rejected` (`settlement_photo`) vẫn còn để đối chiếu |

---

## 9. Triển khai và rollback

**Deploy**
1. Chạy `bin/parallel_rspec` ở local (thêm `--prepare` khi chạy lần đầu hoặc schema thay đổi), sửa nếu fail.
2. Merge vào `main`, redeploy Coolify (migration `create_remitter_transfers` chạy qua `db:prepare`).
3. Admin → **Người đi tiền**: điền Telegram user ID hoặc username cho Lập, Kim, An, Yến, Cô Tuyết.
4. Kiểm tra nhãn `thu chi` của đại lý (`rd_agent_label`) khớp tab thật (`Anh Hải`, `Anh Thọ`, `Chị Mến`, `Tuân` cần sửa).
5. Phát bảng mã §4.3 cho người đi tiền (cũng xem được ở trang HKD).
6. Cài đặt → Telegram: bật **"Bật xử lý người chuyển tiền"**.
7. Chạy kiểm thử tay §6.7.

**Rollback**
- Tắt cờ: không tạo lệnh đi tiền mới; ảnh chuyển khoản bị bỏ qua sau OCR, bill kết toán (kể cả của remitter) vẫn tạo transaction; lệnh đã có giữ nguyên.
- Revert code + `db:rollback` (migration reversible). Hàng đã chèn vào `thu chi` phải xoá tay (tìm theo note `RT<id>`).

---

## 10. Câu hỏi mở

1. ~~Có siết quy tắc dò mã để tránh trùng chữ (rủi ro #1) không~~ → **Đã chốt 12/10/2026: giữ loose** (chịu ký tự thừa `TK01.`/`TK01A`); xem §8 rủi ro #1 và test M9.
2. Bảng tổng hợp cuối tab `thu chi` (`TOTAL AMOUNT`, `REMAINING BALANCE`) có cần tự cộng từ lệnh đi tiền không?
3. Lệnh bị từ chối sau khi ghi: có cần tự xoá hàng trên sheet không?
4. Tên tab `thu chi` từ tháng 11 trở đi: dùng quy ước nào để không trùng (`thu chi 111` = 1/11 hay 11/1)? File có giữ tab của các tháng trước không?

---

## 11. File thay đổi

| Nhóm | File |
|---|---|
| Cấu hình | `merchant_dealers.transfer_code` (migration), `config/routes.rb`, `config/locales/vi.yml` |
| DB | `db/migrate/20261011230000_create_remitter_transfers.rb`, `db/schema.rb` |
| Model | `app/models/remitter_transfer.rb`, `remitter.rb`, `telegram_message.rb`, `permissions.rb` |
| Service | `app/services/remitter_transfers/{codes,code_matcher,classifier,builder,reviewer}.rb`, `app/services/transactions/builder.rb` (§4.10) |
| Sheet | `app/services/workbook/{remitter_report_writer,sheet_lock,sheet_text}.rb`, `hello_smc_writer.rb`, `resolver.rb`, `google_sheet_client.rb`, `memory_sheet.rb` |
| Nhận tin / job | `app/services/telegram/update_receiver.rb`, `app/jobs/{analyze_bill_image,download_telegram_attachment,build_remitter_transfer,write_remitter_report,retry_workbook_writes}_job.rb` |
| Admin | `app/controllers/admin/remitter_transfers_controller.rb`, `app/helpers/remitter_transfers_helper.rb`, `app/views/admin/remitter_transfers/*`, `app/views/admin/merchants/show.html.erb`, `app/views/layouts/admin.html.erb` |
| Task | `lib/tasks/hellosmc.rake` (purge) |
| Spec | `spec/services/remitter_transfers/*`, `spec/services/transactions/single_photo_settlement_only_spec.rb`, `spec/services/workbook/{remitter_report_writer,hello_smc_writer,resolver}_spec.rb`, `spec/requests/admin/remitter_transfers_spec.rb`, `spec/services/remitter_feature_flag_spec.rb`, `spec/factories/remitter_transfers.rb` |
