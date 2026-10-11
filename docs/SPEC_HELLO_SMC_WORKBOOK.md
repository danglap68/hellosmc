# Spec: ghi giao dịch vào Google Sheet Hello SMC khi tạo transaction

Trạng thái: đã implement, **pha 2 (dealer = agent theo TID)**. Album để sau. Phần §15 ghi các quyết định sau review ngày 11/10/2026; khi §15 mâu thuẫn với phần trên thì §15 đúng. File này là hợp đồng cho việc tự điền **Google Sheet** (bản clone từ `Hello SMC.xlsx`) sau khi OCR tạo giao dịch.

Mẫu bố cục (chỉ để đọc khi viết spec/seed, **không ghi**): `/Users/ducnguyen/Documents/work/hellosmc/Hello SMC.xlsx` (đọc ngày 10/10/2026). Bản sống là Google Sheet. Tên tab phải giữ nguyên tên sheet trong file gốc.

| Tên trong yêu cầu | Tên sheet thật |
|---|---|
| Bill_No_Customer | `Bill vô chủ` |
| thu chi (remitter report) | `thu chi {ngày}{tháng}` |
| DS MB T10 | `DS MB T10` |
| MB | `MB` |

Sheet khác trong file, **không đụng** lần này: `DS MB T9`, `DS SP T10`, các tab `thu chi {ngày}{tháng}` trước tháng hiện tại.

## 1. Mục tiêu

Khi `Transactions::Builder` tạo một giao dịch từ bill đã OCR và đã được duyệt, hệ thống ghi **online** vào một Google Sheet (ID cấu hình). Sheets API đọc/ghi ô tại chỗ. Không tải `.xlsx` về, không upload đè, không chờ màn Xuất Excel.

Ba nhánh (chỉ ghi tiền **đã duyệt** — `approved`/`exported`; `needs_review`/`hold`/`pending` bỏ qua tới khi được duyệt):

1. **Không xác định được HKD hoặc không xác định được đại lý (agent)** → thêm một dòng vào `Bill vô chủ`. Không ghi tab `thu chi`, không ghi `DS MB T{tháng}`, không ghi `MB`.
2. **Đã có HKD + đại lý** → cộng dồn ô ngày trên `DS MB T{tháng}` và thêm một dòng vào `MB`.
3. **Đã có HKD + đại lý + người chuyển tiền (remitter)** → thêm bước cộng dồn ô remitter trên tab `thu chi {ngày}{tháng}`.

Một HKD có nhiều đại lý. Một đại lý đứng dưới nhiều HKD. Cặp (HKD, đại lý) phân biệt bằng TID trên bill (tid1, tid2, tid3, hoặc `TID 127`).

## 2. Ngoài phạm vi

- Album (nhiều ảnh + ảnh quyết toán): để sau.
- Không ghi `DS SP T*`, `DS MB T9` (trừ khi tháng giao dịch là tháng 9 và sheet đó là sheet tháng hiện tại — lần này chỉ tạo/ghi `DS MB T{n}`).
- Không đổi file xuất `legacy` / `ket_toan_phi_goc` trên `/admin/excel_exports`.
- Không đổi công thức `Transactions::Calculator` hay cách chọn fee rule.
- Không map `telegram_user_id` / `telegram_username` của remitter trong seed. Seed chỉ tên. Admin map sau.
- Không ghi file `.xlsx` local, kể cả `Hello SMC.xlsx` trong repo. File đó chỉ là mẫu bố cục.
- Không commit JSON service account, `credentials.json`, hay spreadsheet ID chứa secret. ID sheet nằm trong setting/ENV. JSON nằm `GOOGLE_SHEETS_CREDENTIALS_JSON` hoặc Rails credentials, không check-in.

## 3. File thật (đã đọc)

### 3.1 `DS MB T10`

Nhiều bảng nằm ngang. Mỗi bảng:

- Ô góc trái hàng 1: tên HKD (`Thiên Kim GV `, `Gat Tan Day Coffe`, `Cherry Coffee`, `HKD AS CAFE-CAFE MILO`, `HKD AS CAFE-CAFE 96`, bảng dưới `HKD AS CAFE`).
- Các cột kế: đại lý kèm TID, ví dụ `Chương (tid1)`, `Sơn(tid2)`, `Hải (tid3)`, `Chị Huệ (TID 127)`.
- Cột ngày: 1/10/2026 … 31/10/2026.
- Ô tiền là **số**, không phải công thức. Cuối bảng có `Tổng cộng` = `=SUM(...)`.

Ví dụ Thiên Kim GV (cột A–D, hàng 1–32):

| | A | B | C | D |
|---|---|---|---|---|
| 1 | Thiên Kim GV | Chương (tid1) | Sơn(tid2) | Hải (tid3) |
| 2 | 01/10/2026 | 354.367.000 | 239.332.000 | 117.362.000 |
| 3 | 02/10/2026 | 101.068.000 | 746.622.000 | |

Cùng một người (Cường Duyên, Trân) xuất hiện ở nhiều HKD với TID khác nhau. Seed phải giữ cặp (HKD, đại lý, tid), không gộp thành một cột.

### 3.2 `thu chi {ngày}{tháng}` (remitter report)

Một tab **mỗi ngày**, tên không zero-pad: `thu chi 110` = 1/10, `thu chi 910` = 9/10, `thu chi 1010` = 10/10. Hàng 2 lặp năm remitter: `LẬP`, `KIM`, `AN`, `YẾN`, `CÔ TUYẾT` — mỗi khối đại lý một cụm remitter.

Mỗi đại lý chiếm một khối: hàng nhãn đại lý (nhiều dòng `Chương\n(MB+SP)`, kênh chỉ để người đọc) + các hàng nhập + một hàng `TOTAL` (`=SUM`). Ô ghi = cột remitter, **hàng trống đầu tiên** trong khối (giữa nhãn đại lý và `TOTAL`), không cộng dồn vào một ô.

Tab `thu chi` **không** là công thức kéo từ `DS MB T10`. Hai sheet khác hạt: `DS MB` theo (HKD, đại lý, ngày); `thu chi` theo (đại lý, remitter, ngày). Cùng một giao dịch ghi cả hai.

### 3.3 `MB`

Một sheet, cột A–K. Hàng 1 header. Hàng 2–1000 đã có sẵn công thức B/C/E, cột D mặc định `0.014`. Cột A đang trống.

| Cột | Header | Nguồn khi ghi |
|---|---|---|
| A | Số tiền giao dịch | `transaction_amount_vnd` |
| B | Số tiền đã khấu trừ cho đại lý | Giữ công thức sẵn `=A{n}-(A{n}*D{n})` |
| C | Số tiền sau khi trừ phí gốc | Ghi đè công thức theo mức đã dùng để tính, giống Kết toán theo phí gốc (`1.21%` hoặc `0.88%`) |
| D | Tỷ lệ | `applied_dealer_rate` |
| E | Lợi nhuận | Giữ hoặc ghi `=A{n}*(D{n}-{formula_percent})` cho khớp C |
| F | Số Lô | `lot_number` |
| G | Ngày giao dịch | ngày của `transaction_at` |
| H | Giờ giao dịch | giờ của `transaction_at` |
| I | Tên đại lý | tên agent đã resolve |
| J | Tên HKD | tên merchant đã resolve |
| K | Người đi tiền | tên remitter, trống nếu chưa map |

Không chia sheet theo phí gốc. Tìm hàng đầu tiên cột A trống, điền hàng đó.

### 3.4 `Bill vô chủ`

Cùng bố cục file xuất cũ (`legacy`): Tên Đại lý, Số tiền sau khi trừ phí gốc (công thức `=C-C*D`), Số tiền giao dịch, Phí gốc, Ngày giao dịch, Trạng thái. Thêm dòng cuối. Cột A lấy tên OCR nếu có, không thì `—`.

## 4. Model

Hiện tại `Merchant belongs_to :dealer` (một hộ một đại lý) và `TelegramChat belongs_to :dealer`. Group Thiên Kim GV là group **HKD**, đại lý lấy từ TID trên bill. Phải đổi.

### 4.1 Bảng mới / đổi

**`merchant_dealers`** (join nhiều-nhiều + TID):

| Cột | Ý nghĩa |
|---|---|
| `merchant_id` | HKD |
| `dealer_id` | Agent (Chương, Sơn, …) |
| `tid_key` | Chuẩn hóa: `tid1`, `tid2`, `tid3`, `tid127` |
| `tid_label` | Chuỗi như trên header: `tid1`, `TID 127` |
| `ds_sheet_anchor` | Tên HKD đúng header `DS MB` (`Thiên Kim GV`) để tìm bảng |
| `ds_header` | Header cột đại lý (`Chương (tid1)`) |
| `rd_agent_label` | Nhãn khối tab `thu chi` (`Chương`) |
| `active` | |

Unique `(merchant_id, dealer_id, tid_key)`. Unique `(merchant_id, tid_key)` trong các dòng active: một TID dưới một HKD chỉ một đại lý.

**`remitters`:**

| Cột | Ý nghĩa |
|---|---|
| `name` | `Lập`, `Kim`, `An`, `Yến`, `Cô Tuyết` |
| `excel_key` | `LẬP`, `KIM`, `AN`, `YẾN`, `CÔ TUYẾT` — khớp hàng 2 tab `thu chi` |
| `telegram_user_id` | nullable, map sau |
| `telegram_username` | nullable, map sau, không phân biệt hoa thường khi so |
| `active` | |

Unique `excel_key`. Unique `telegram_user_id` khi có giá trị.

**`workbook_entries`** (sổ để không cộng hai lần):

| Cột | Ý nghĩa |
|---|---|
| `transaction_id` | unique |
| `spreadsheet_id` | ID Google Sheet đã ghi |
| `branch` | `identified` / `unidentified` |
| `ds_sheet` | ví dụ `DS MB T10` |
| `ds_cell` | ví dụ `B2` |
| `rd_cell` | ví dụ `H3`, null nếu không có remitter |
| `mb_row` | số hàng sheet `MB` |
| `unidentified_row` | số hàng `Bill vô chủ` |
| `amount_vnd` | số đã cộng |
| `payload` | jsonb: merchant, dealer, tid, remitter, ngày |

**Quan hệ (pha 2, đã áp dụng):**

- `Merchants.dealer_id` và `telegram_chats.dealer_id` đã **bị xoá** (migration `drop_legacy_dealer_columns`, không backfill).
- Dealer của giao dịch = agent theo TID: `Dealers::Resolver` tra `merchant_dealers` theo `(merchant, tid_key)` lấy từ tên merchant trên OCR. Không còn "chat → dealer" và không còn `manual_dealer_id`.
- Merchant chưa có `merchant_dealers` hoặc tên không có hậu tố TID → `dealer_unmapped` → `needs_review` (hành vi mong đợi, người duyệt xử lý).
- `Merchant`: `has_many :merchant_dealers`, `has_many :dealers, through:`. `TelegramChat`: `belongs_to :merchant` (group = HKD, dùng làm fallback resolve HKD).
- `TelegramMessage`: thêm `telegram_username` (lấy `from.username`).
- `Merchants::Resolver` không còn disambiguation theo dealer; nhiều khớp → `ambiguous`.

### 4.2 Seed remitter

Năm dòng, `telegram_user_id` / `telegram_username` để trống:

| name | excel_key |
|---|---|
| Lập | LẬP |
| Kim | KIM |
| An | AN |
| Yến | YẾN |
| Cô Tuyết | CÔ TUYẾT |

### 4.3 Seed agent × HKD từ `DS MB T10`

Script đọc header một lần, tạo merchant (nếu chưa có theo alias/tên), dealer, và `merchant_dealers`. Không ghi đè tid đã có.

Bảng trên `DS MB T10` (hàng 1 và hàng 39):

| Header HKD | Đại lý | tid_key |
|---|---|---|
| Thiên Kim GV | Chương | tid1 |
| Thiên Kim GV | Sơn | tid2 |
| Thiên Kim GV | Hải | tid3 |
| Gat Tan Day Coffe | Cường Duyên | tid1 |
| Gat Tan Day Coffe | Trân | tid2 |
| Gat Tan Day Coffe | Thọ | tid3 |
| Cherry Coffee | Cường Duyên | tid2 |
| Cherry Coffee | Trân | tid3 |
| Cherry Coffee | Nghĩa Nghiệp | tid1 |
| HKD AS CAFE-CAFE MILO | Chị Huệ | tid127 |
| HKD AS CAFE-CAFE MILO | Chị Huệ | tid128 |
| HKD AS CAFE-CAFE MILO | Chị Huệ | tid129 |
| HKD AS CAFE-CAFE 96 | PHÙNG CUỜNG | tid1 |
| HKD AS CAFE-CAFE 96 | Anh Hiếu | tid2 |
| HKD AS CAFE-CAFE 96 | (trống, chỉ TID 3) | tid3 |
| HKD AS CAFE | Anh Hải | tid1 |
| HKD AS CAFE | Anh Hùng | tid2 |
| HKD AS CAFE | Chị Hồng | tid3 |

Merchant trong app hiện có (`001_ HỘ KINH DOANH THIÊN KIM GV`, `HKD AS CAFE-CAFE 96-2`, `CHERRY COFFE 2`, …) map sang header bằng alias / `normalized_name`, không tạo bản ghi trùng nếu đã khớp. Với merchant cũ có tên/code khác biệt (`CHERRY COFFE 2` vs `Cherry Coffee`), seed dùng `match_code` để khớp đúng merchant cũ (`002 CHERRY COFFE 2`, `099`) thay vì tạo trùng.

`rd_agent_label` map tay trong seed khi tên tab `thu chi` khác DS MB (`NamHai` vs `Hải`, `PCuong` vs `PHÙNG CUỜNG`, `HiêuSG` vs `Anh Hiếu`). Spec test bắt buộc có map cho Chương, Sơn, Hải / NamHai.

Seed chạy lại được (idempotent) và **ghi đè** `tid_label`, `ds_header`, `ds_sheet_anchor`, `rd_agent_label` theo seed cho link đã có (không đụng `active`). `rd_agent_label` là tên đại lý trần như header tab `thu chi` (`Mến`, `Thọ`, không có `Chị`/`Anh`); `Anh Hải` và `Tuân` chưa xác nhận. `db/seeds.rb` (dev) gọi thêm `Workbook::Seed.seed_telegram_chats`: mỗi đại lý một nhóm demo tên `TenDaiLy-HKD1-HKD2`, gắn đủ HKD của đại lý.

## 5. Cách chọn HKD, đại lý, remitter

Thứ tự sau OCR, trong `Workbook::Resolver` (cùng nguồn TID với `Dealers::Resolver`, nên agent trên sheet và dealer của fee rule là một):

```
HKD:
  1. Merchants::Resolver (tên / MID trên bill) như hiện tại
  2. Nếu không ra: telegram_chat.merchant
  3. Vẫn không ra: unidentified

Đại lý (chỉ khi đã có HKD) — **đã implement** trong `Transactions::Evaluator#check_merchant` + `Dealers::Resolver`:
  1. TID / hậu tố trên tên merchant OCR: "... GV-1", "tid1", "TID 127"
  2. Số cuối cách dấu cách ("CHERRY COFEE 2"): chỉ coi là TID khi bỏ số đó ra
     vẫn resolve được merchant **exact** (alias/tên); nếu không, số là một phần
     tên HKD ("HKD AS CAFE-CAFE 96", "CƯỜNG DUYÊN 1")
  3. Tra merchant_dealers của HKD đó theo tid_key
  4. Không ra: unidentified (dù đã có HKD)

TID của đại lý chỉ lấy từ **tên merchant trên OCR**, không lấy từ
`terminal_or_merchant_id` (trường đó dùng để map HKD, có thể là MID, không
phân biệt được agent).

Alias chính tả OCR (vd `CHERRY COFEE` → `Cherry Coffee`) được thêm vào
`merchant_aliases` (`alias_type: receipt_name`) qua seed (`Workbook::Seed`) hoặc
admin; giúp merchant khớp **exact** thay vì `merchant_fuzzy_match`.

Remitter:
  1. telegram_sender_id = remitters.telegram_user_id
  2. telegram_username (không phân biệt hoa thường) = remitters.telegram_username
  3. Không ra: remitter = null. Vẫn ghi DS MB + MB nếu đã có HKD+đại lý. Không cộng tab `thu chi`.
```

Ví dụ trong yêu cầu: group HKD Thiên Kim GV, người gửi Lập (`telegram_user_id` sau này = 1234567890), bill hiện `HỘ KINH DOANH THIÊN KIM GV-1` → HKD Thiên Kim GV, `tid1` → Chương, remitter Lập.

Chưa map remitter thì bước `thu chi` bỏ qua, hai sheet kia vẫn ghi.

## 6. Khi nào ghi

Sau `Transactions::Builder#finish` khi giao dịch vừa tạo hoặc vừa rebuild từ `processing`. Job `WriteHelloSmcWorkbookJob` (queue `exports`), không ghi trong request Telegram.

Không ghi lại nếu đã có `workbook_entries` cho `transaction_id` (trừ khi rebuild và entry bị xóa tay).

Giao dịch `failed`/`rejected`/`needs_review`/`hold`: không ghi. Chỉ ghi `approved`/`exported`. Nhánh unidentified (thiếu TID hoặc thiếu ô DS MB) ghi vào `Bill vô chủ`.

Số cộng dồn: `transaction_amount_vnd` (số trên bill), không dùng tiền sau phí gốc. Các ô ngày trên `DS MB T10` hiện đang là số giao dịch gốc.

## 7. Ghi Google Sheet

Nguồn sống: một spreadsheet native (đã File → Save as Google Sheets / convert khi upload). URL dạng `https://docs.google.com/spreadsheets/d/{SPREADSHEET_ID}/edit`. Setting `hello_smc_spreadsheet_id`. Thiếu ID (`ConfigurationError`) → job **discard + log error** (không retry vô ích, tránh flood retry queue). API 403/404/network (`Google::Apis::Error`) → job fail + retry 5 lần (polynomial backoff), không im lặng.

Writer trả về các cờ skip (không ghi, không tạo entry): `:skipped_no_amount` (thiếu số tiền), `:skipped_failed` (giao dịch failed), `:skipped_rejected` (giao dịch bị từ chối), `:skipped_not_approved` (`needs_review`/`hold`/`pending` — chỉ ghi sau khi duyệt), `:already_written` (đã có `workbook_entries`). Vì chỉ ghi giao dịch đã duyệt (`finalized?`), các guard `:skipped_no_date`/`merchant_missing` không còn chạm tới (finalized luôn có ngày + HKD).

**Auth.** Service account, scope `https://www.googleapis.com/auth/spreadsheets`. Share spreadsheet cho email service account, quyền Editor. Không dùng OAuth user cho job nền.

**Gem.** `google-apis-sheets_v4`. Không cần Drive API nếu đã có spreadsheet ID.

**Client.** `Workbook::GoogleSheetClient`: `get_values(range)`, `update_values(range, values)`, `append_values(range, values)`, `duplicate_sheet(source_title:, dest_title:)`, `sheet_titles`. Test stub client này, không gọi mạng.

**Khóa ghi.** Advisory lock Postgres theo `spreadsheet_id` (tránh hai giao dịch đọc-cộng-ghi cùng ô). Google không lock ô; app phải serialize. Dùng **session-level** `pg_try_advisory_lock`/`pg_advisory_unlock` quanh toàn bộ read→compute→write (khoá bận → `LockBusy` → job retry, không chặn thread Sidekiq); nếu dùng `pg_advisory_xact_lock` thì phải bọc `write_*` trong một `ActiveRecord::Base.transaction` để lock giữ đến commit (lock ngoài transaction sẽ nhả ngay, vô tác dụng). Sau khi lock xong phải kiểm tra lại `workbook_entries` trước khi ghi.

**Một lần ghi.** Đọc các ô cần cộng → tính số mới → gom mọi ô/hàng của giao dịch đó (DS MB + `thu chi` + MB, hoặc chỉ Bill vô chủ) vào **một** `values.batchUpdate` duy nhất → mới tạo `workbook_entries`. Client phải có method `batch_update_values` (không ghi từng ô bằng `update` riêng lẻ). Fail giữa chừng: không tạo entry, job retry. Retry phải idempotent: đã có entry thì dừng.

### 7.1 `DS MB T{tháng}`

`tháng` = tháng của `transaction_at` (timezone app). Tên sheet `DS MB T10`, `DS MB T11`, không zero-pad hai chữ số nếu tháng < 10? File đang dùng `T9` và `T10` → **`DS MB T#{month}`** không pad (`T9`, không `T09`).

Không có sheet:

1. `spreadsheets.batchUpdate` `DuplicateSheet` từ tab `DS MB T*` có số tháng lớn nhất.
2. Đổi title thành `DS MB T{tháng mới}`.
3. Đổi cột ngày thành 1…cuối tháng mới (timezone app). Ghi ngày dạng ISO string `YYYY-MM-DD` để Google (USER_ENTERED) parse thành date; đọc về là serial qua `UNFORMATTED_VALUE`. `date_of` chấp nhận cả serial lẫn ISO string để round-trip.
4. Xóa số tiền các ô ngày (để trống), giữ công thức `=SUM`.

Tìm bảng: hàng header có ô = `ds_sheet_anchor` của `merchant_dealers`. Trong các cột của bảng đó, header khớp `ds_header` (chuẩn hóa khoảng trắng). Hàng ngày = ô ngày cùng `transaction_at.to_date`. Đọc ngày **deterministic** (serial number qua `valueRenderOption=UNFORMATTED_VALUE` / `DATE_TIME`), so sánh theo `to_date`; không `Date.parse` chuỗi `dd/mm/yyyy` vì Ruby parse theo `mm/dd` sẽ lệch ngày.

Cộng: `ô = (ô.to_f) + amount`. Ghi **số**, không ghi `=cũ+mới` (file đang dùng số; `SUM` cuối bảng là công thức cần giữ).

Không tìm được sheet / bảng / cột / hàng ngày → không đoán. Ghi `Bill vô chủ` và `workbook_entries.branch = unidentified` kèm lý do `ds_cell_missing`.

### 7.2 `thu chi {ngày}{tháng}`

Chỉ khi có remitter. Tab = `thu chi #{day}#{month}` (timezone app, không zero-pad), chọn từ `client.titles`.

Tìm khối: ô nhãn đại lý chứa `rd_agent_label` (tên trần, không kênh). So khớp: normalize không dấu → tách theo dòng nếu ô nhiều dòng → bỏ kênh (chỉ để người đọc). Cột remitter = cột trong cùng khối có hàng 2 = `excel_key`. Ô ghi = cột đó, **hàng trống đầu tiên** trong khối (giữa nhãn đại lý và hàng `TOTAL`).

Không tìm thấy khối/cột/hàng trống → không cộng `thu chi`, vẫn ghi DS MB + MB, ghi mã lỗi (`rd_agent_missing`/`rd_remitter_missing`/`rd_total_missing`/`rd_block_full`) vào payload. Không chuyển sang Bill vô chủ.

Remitter mới chưa có cột: `insert_columns` chèn thêm một cột trống vào cuối mỗi khối (chỉ các hàng của khối, giữ nguyên vùng kế toán thủ công phía dưới), copy định dạng cột kế bên, dịch công thức `=SUM`.

### 7.3 `MB`

Hàng trống đầu tiên ở cột A. Điền A, D, F–K. Sửa C (và E nếu cần) theo `base_fee_rate_used`: `0.0088` → `0.88%`, `0.0121` → `1.21%`. Không đụng hàng đã có A.

Hết 1000 hàng: thêm hàng mới, copy công thức B/C/E từ hàng trên.

### 7.4 `Bill vô chủ`

Hàng trống đầu tiên. A = tên OCR hoặc `—`. C = `transaction_amount_vnd`. D = `base_fee_rate_used` hoặc 0.0088 nếu chưa tính. E = `transaction_at`. F = `Thành công` nếu approved, không thì `Cần kiểm tra`. B giữ/ghi `=C{n}-(C{n}*D{n})`.

## 8. Admin

- CRUD remitter: tên, excel_key, telegram_user_id, telegram_username.
- Form HKD: tick nhiều đại lý, mỗi dòng một TID + header DS MB + nhãn `thu chi`.
- Form group Telegram: thêm chọn HKD (`merchant_id`) cho fallback resolve; **vẫn giữ** `dealer_id` (fee rule) trong pha 1, bỏ ở pha 2.
- Trang giao dịch: hiện remitter, tid, ô đã ghi (`ds_cell`, `rd_cell`, `mb_row`) nếu có entry.

## 9. Ví dụ chốt (Lập → Chương tid1, 01/10/2026)

Bill 486.000, HKD Thiên Kim GV, tid1, remitter Lập (sau khi đã map).

| Sheet | Ô / hàng | Trước | Sau |
|---|---|---|---|
| `DS MB T10` | B2 (01/10, Chương tid1) | 354.367.000 | 354.853.000 |
| `thu chi 1010` | H3 (Chương × LẬP) | (trống hoặc số cũ) | cũ + 486.000 |
| `MB` | hàng A trống đầu tiên | A trống | A=486000, I=Chương, J=Thiên Kim GV, K=Lập |
| `Bill vô chủ` | — | không thêm | |

Thiếu map remitter: B2 và MB vẫn ghi, H3 không đổi.

Thiếu HKD hoặc tid: chỉ `Bill vô chủ`.

## 10. Rủi ro và điểm mở

1. **Phải là Google Sheet native.** File `.xlsx` chỉ nằm trên Drive thì API Sheets không ghi tab được. Phải convert / “Save as Google Sheets”.
2. **Share service account.** Quên share → 403. Job fail có log, giao dịch vẫn còn.
3. **Quota.** Sheets API khoảng 60 ghi/phút/project. Mỗi giao dịch một `batchUpdate`. Hai job cùng ô: advisory lock trong app.
4. **Cộng hai lần.** `workbook_entries.transaction_id` unique. Rebuild không ghi lại trừ khi xóa entry.
5. **Tab `thu chi` không SUM từ DS MB.** Hai tab ghi độc lập. `batchUpdate` một lần cho cả giao dịch để khỏi lệch giữa chừng.
6. **TID trên OCR.** Parser (`-1`, `tid1`, `TID 127`, và số cuối cách dấu cách khi strip vẫn khớp merchant exact). Không đoán khi tên không có hậu tố.
7. **Nhãn `thu chi` ≠ header DS MB** (`Hải` vs `NamHai`). Seed phải có `rd_agent_label`.
8. **Tháng mới.** `DuplicateSheet`; sai header thì T11 hỏng. Test tạo T11 từ T10 (stub API).
9. **Chị Huệ ba TID** (127/128/129) cùng người, ba cột. Không gộp.
10. **Secret.** Không commit JSON service account. Không đưa spreadsheet ID vào spec hay git nếu coi là nội bộ — để ENV.
11. **Thiếu `transaction_at`.** Không còn guard riêng vì writer chỉ ghi `approved`/`exported` (luôn có `transaction_at`).
12. **Thiếu `spreadsheet_id`.** `ConfigurationError` được `discard_on` + log error trong job (không retry 25 lần mặc định của Sidekiq → không flood queue).

## 11. Test case

### 11.1 Remitter

- Seed 5 remitter, chưa có telegram id.
- Map `telegram_user_id` rồi resolve đúng.
- Map `telegram_username` (hoa thường) đúng.
- Trùng id → không lưu.
- Không map → remitter nil, không fail.

### 11.2 merchant_dealers

- Thiên Kim GV + tid1 → Chương.
- Cường Duyên tid1 (Gat Tan Day) ≠ tid2 (Cherry).
- Một HKD không được hai đại lý cùng tid_key.
- Một đại lý hai HKD: hợp lệ.

### 11.3 Workbook::Resolver

- OCR HKD + `...GV-1` + sender đã map Lập → identified, Chương, Lập.
- OCR HKD, không có tid → unidentified, lý do `agent_tid_missing`.
- Không ra HKD, chat đã map merchant, bill có tid → identified.
- Không HKD, không chat merchant → unidentified.

### 11.4 DS MB T10

- 01/10 Chương tid1: B2 tăng đúng `transaction_amount_vnd`.
- 02/10: B3, không đụng B2.
- Không đụng cột Sơn / Hải.
- Giữ `=SUM` ở B35.
- Chạy job hai lần cùng giao dịch: B2 không tăng lần hai.

### 11.5 Tháng mới

- Giao dịch 01/11, chưa có `DS MB T11`: tạo sheet, ngày tháng 11, B2 (hoặc ô tương ứng) = amount, T10 không đổi.

### 11.6 Tab `thu chi`

- Lập + Chương → H3 tăng (hàng trống đầu tiên của khối), cột khác không đổi, `=SUM` giữ.
- Kim + Chương → cột của Kim, không phải cột Lập.
- Identified nhưng remitter nil → không đổi tab `thu chi`.
- Không tìm thấy nhãn đại lý → DS MB + MB vẫn ghi, payload ghi mã lỗi.

### 11.7 MB

- Hàng trống đầu tiên: A = amount, D = dealer rate, I/J/K đúng, C dùng `0.88%` khi `base_fee_rate_used` là 0,88%.
- Không ghi đè hàng đã có A.
- Có cột K người đi tiền.

### 11.8 Bill vô chủ

- Thiếu tid (thiếu HKD): thêm một dòng, không đổi T10 / `thu chi` / MB.
- Identified: không thêm dòng.

### 11.9 Builder / job

- `Builder` enqueue `WriteHelloSmcWorkbookJob` sau khi tạo giao dịch có số tiền **và có `transaction_at`**.
- OCR failed: không enqueue.
- Thiếu `hello_smc_spreadsheet_id`: job discard + log error, giao dịch vẫn tồn tại, không có `workbook_entries`, không retry.
- API 403/404: job fail + retry (Google::Apis::Error), giao dịch vẫn còn.
- Client Sheets được stub; spec không gọi Google thật.

### 11.10 Parser TID

- `HỘ KINH DOANH THIÊN KIM GV-1` → `tid1`.
- `Chị Huệ (TID 127)` / `TID 127` trên tên → `tid127`.
- Không hậu tố → nil.

### 11.11 Writer — khóa ghi & idempotent

- Hai job cùng `spreadsheet_id` ghi cùng lúc vào 1 ô: advisory lock serialize; ô cuối = `cũ + amountA + amountB` (không mất cập nhật).
- Chạy lại job cùng `transaction_id` khi đã có `workbook_entries`: dừng sớm (`:already_written`), không ghi lại sheet.
- `workbook_entries.transaction_id` unique: cố tạo trùng → lỗi, không ghi sheet lần hai.

### 11.12 Writer — batchUpdate một lần

- Giao dịch identified + có remitter: mọi ô (DS MB + `thu chi` + MB) gộp vào **một** `values.batchUpdate`; client không bị gọi `update` từng ô.
- Stub client đếm số lần gọi `batch_update_values`: đúng **1** cho một giao dịch.
- Mock `batch_update_values` raise giữa chừng: không tạo `workbook_entries`; retry ghi lại trọn vẹn (idempotent).

### 11.13 Tab `thu chi` — nhãn agent có kênh `(MB+SP)`

- Ô nhãn `Chương (MB+SP)` (1 dòng) khớp `rd_agent_label` = `Chương`.
- Ô nhãn nhiều dòng (dòng đầu = `Chương`) khớp.
- `rd_agent_label` map tay (`NamHai` từ `Hải`) vẫn khớp đúng khối của Hải.

### 11.14 Ngày — đọc deterministic

- Ô ngày là serial number (`valueRenderOption=UNFORMATTED_VALUE`): 01/10/2026 → đúng hàng B2; 02/10 → B3.
- Không parse chuỗi `01/10/2026` bằng `Date.parse` (tránh lệch mm/dd).
- Ngày không khớp hàng nào → `ds_cell_missing` → ghi `Bill vô chủ`.

### 11.15 Tháng mới — tạo T11 đúng

- Duplicate từ sheet `DS MB T*` có **số tháng lớn nhất** (T10, không phải T9).
- Sheet mới đổi cột ngày thành 1…31/11 (timezone app); xoá số tiền các ô ngày; giữ công thức `=SUM`.
- Giao dịch 01/11 ghi đúng ô ngày tháng 11; `DS MB T10` không đổi.

### 11.16 MB — rate nil & percent chính xác

- `base_fee_rate_used = 0.0088` → C dùng `0.88%`; `0.0121` → `1.21%` (khớp `KetToanPhiGocLayout.formula_percent_for`).
- Rate không đúng 2 chữ số thập phân (vd `0.00881`): **không** làm tròn thành `0.88%`; xử lý như export (skip/fallback), không crash.
- (Đã bỏ) `needs_review` không còn ghi sheet.

### 11.17 Cấu hình thiếu / lỗi API

- Thiếu `hello_smc_spreadsheet_id`: job **discard + log error** (không im lặng, không retry), không tạo entry — không phải `:skipped_unconfigured` bỏ qua.
- Thiếu credentials / chưa share service account (403): job fail + retry, giao dịch vẫn còn.
- Sheets API 404 (sheet không tồn tại): fail, không tạo entry.
- (Đã bỏ) `:skipped_no_date` — `approved` luôn có `transaction_at`.

### 11.18 Resolver — TID chỉ từ tên merchant

- `merchant_name = "HỘ KINH DOANH THIÊN KIM GV-1"`, `terminal_or_merchant_id = "127"` → tid từ tên = `tid1` (KHÔNG dùng `terminal_or_merchant_id`).
- `merchant_name` không hậu tố nhưng `terminal_or_merchant_id = "TID 127"` → vẫn `agent_tid_missing` (terminal không dùng để tìm agent).

### 11.19 Agent nhiều HKD & Chị Huệ

- Cường Duyên: `(Gat Tan Day, tid1)` và `(Cherry, tid2)` → hai dòng `merchant_dealers`; resolve theo đúng cặp (HKD, tid).
- Chị Huệ 3 TID (127/128/129) cùng HKD: ba cột, không gộp; mỗi tid ghi đúng cột của nó.
- Một đại lý nhiều HKD: hợp lệ; resolve theo HKD hiện tại.

### 11.20 Dealer = agent (pha 2)

- `transaction.dealer` (từ TID) = "Chương"; cột I sheet MB ghi **"Chương"**; fee rule nhận cùng dealer đó.
- Merchant không có `merchant_dealers` hoặc tên không hậu tố TID → `dealer_unmapped` → `needs_review` (không ghi sheet tới khi duyệt).

### 11.21 Seed merchant_dealers

- Chạy seed lại: không tạo merchant/dealer trùng nếu đã khớp alias/`normalized_name`; không ghi đè `tid_key` đã có.
- `rd_agent_label` map tay đúng cho Chương, Sơn, Hải/NamHai.

### 11.22 Client — GoogleSheetClient

- `duplicate_sheet` chọn nguồn là sheet `DS MB T*` có tháng lớn nhất.
- `titles` / `values` / `update` / `batch_update_values` được stub; spec không gọi mạng.
- `values` đọc `UNFORMATTED_VALUE` để nhận số/ngày đúng kiểu.

### 11.23 Model validation

- `Remitter`: `excel_key` unique (case-insensitive qua normalize); `telegram_user_id` / `telegram_username` unique khi có giá trị.
- `MerchantDealer`: normalize `tid_key` (`TID 127` → `tid127`); unique `(merchant_id, tid_key)` với active.
- `WorkbookEntry`: `transaction_id` unique; `branch` ∈ `{identified, unidentified}`.

## 12. Thứ tự implement

1. Migration `remitters`, `merchant_dealers`, `workbook_entries`; `telegram_chats.merchant_id`; `telegram_messages.telegram_username`.
2. Seed 5 remitter + script/seed `merchant_dealers` từ mẫu `DS MB T10` (xlsx hoặc dump đã chốt ở mục 4.3).
3. `Remitters::Resolver`, `Workbook::TidParser`, `Workbook::Resolver`.
4. `Workbook::GoogleSheetClient` + `Workbook::HelloSmcWriter` (cộng DS MB, cộng tab `thu chi`, append MB, append Bill vô chủ, `DuplicateSheet` T{n+1}).
5. Setting `hello_smc_spreadsheet_id` + ENV credentials. Gem `google-apis-sheets_v4`.
6. `WriteHelloSmcWorkbookJob` + gọi từ `Builder`.
7. Admin remitter + form HKD nhiều đại lý + chat → HKD.
8. Spec ở mục 11, stub client. Không đụng album. Không ghi `.xlsx` local.

## 13. Quyết định đã khóa trong spec

| # | Quyết định |
|---|---|
| 1 | Tên sheet dùng tên thật trong file. |
| 2 | Số cộng = `transaction_amount_vnd`. |
| 3 | Ô ngày / ô remitter ghi **số cộng dồn**, không ghi chuỗi `=cũ+mới`. Giữ `SUM` có sẵn. |
| 4 | Thiếu remitter: vẫn ghi DS MB + MB, bỏ tab `thu chi`. |
| 5 | Thiếu HKD hoặc thiếu đại lý: chỉ `Bill vô chủ`. |
| 6 | Group Telegram = HKD, không phải đại lý. Đại lý = TID. |
| 7 | Ghi lúc tạo giao dịch (job), không lúc xuất Excel. |
| 8 | Một giao dịch chỉ ghi workbook một lần (`workbook_entries`). |
| 9 | Tháng mới: `DuplicateSheet` tab `DS MB T*` mới nhất, đổi ngày. |
| 10 | Album không làm trong spec này. |
| 11 | Bản sống là Google Sheet. Ghi bằng Sheets API. Không ghi `.xlsx` trên disk hay upload đè file Drive. |
| 12 | TID đại lý chỉ parse từ tên merchant OCR; `terminal_or_merchant_id` không dùng để tìm agent. |
| 13 | Ghi một lần: một `values.batchUpdate` duy nhất cho toàn bộ ô của giao dịch. |
| 14 | Khóa ghi bằng session-level advisory lock (hoặc xact lock bọc trong transaction). |
| 15 | Ngày trên `DS MB` đọc bằng serial/`DATE_VALUE`, không `Date.parse` chuỗi locale. |
| 16 | Nhãn `thu chi`: normalize + bỏ kênh trước khi so. |
| 17 | Pha 2 đã áp dụng: dealer = agent theo TID (§14). |

## 14. Pha 2: gộp `dealer` = `agent` (ĐÃ LÀM)

Làm riêng, chỉ sau khi pha 1 chạy ổn và có spec test cho fee rule. Khi đó thống nhất một khái niệm dealer = agent TID:

- `Dealers::Resolver` resolve theo **TID** (tra `merchant_dealers` theo `(merchant, tid_key)`); bỏ "chat → dealer" và `manual_dealer_id`.
- `Evaluator`/`Builder` đảo thứ tự: merchant trước → dealer từ TID → fee rule; bỏ check `merchant_dealer_mismatch`.
- `Merchants::Resolver` bỏ disambiguation theo `dealer`; `Merchant.dealer_id` nullify rồi drop.
- `TelegramChat.dealer_id` drop; `FeeRule#merchant_belongs_to_dealer` chuyển sang `merchant_dealers`.
- Export/review/dashboard tự khớp agent (chỉ đổi nghĩa `transaction.dealer`, không đổi logic hiển thị).
- Data migration: chỉ drop cột `dealer_id` cũ, **không backfill** `merchant_dealers` (tid1 tổng hợp sẽ xung đột unique `(merchant_id, tid_key)` với seed thật). Mapping thật do `Workbook::Seed` tạo từ DS MB.

## 15. Quyết định sau review (11/10/2026)

**Idempotent khi retry.** Mỗi dòng sổ có marker `TX<id>`: sheet `MB` cột **L**, sheet `Bill vô chủ` cột **G**. Writer đọc sổ (`A:L` / `A:G`) trong khoá; thấy marker nghĩa là lần trước đã ghi nhưng chưa lưu `workbook_entries` (timeout sau khi Google đã áp dụng, crash, lỗi DB). Khi đó chỉ tạo `workbook_entries` (`payload.issue = reconciled_after_retry`), không cộng lại. Không xoá cột L/G trên sheet. Giới hạn: nếu lần đầu ghi vào `MB` nhưng lần retry resolve ra nhánh `Bill vô chủ` (hoặc ngược lại) thì không phát hiện được.

**Khoá.** `pg_try_advisory_lock`; bận thì `HelloSmcWriter::LockBusy`, job `retry_on` (3s, jitter, 30 lần).

**Guard.** Thêm `:skipped_rejected`. Không chặn `hold` (không có chỗ enqueue lại khi hold → approved). Giao dịch đã ghi rồi mới bị reject hoặc sửa số tiền **không** được đảo ngược trên sheet: phải trừ tay (xem ticket cảnh báo UI).

**Sổ MB / Bill vô chủ.** Tìm hàng trống đầu tiên trên mảng 2-D gốc (không `flatten`; API có thể trả `[]`, `[""]` hoặc bỏ hàng cuối). Hết hàng thì `appendDimension` thêm hàng. Ngày/giờ ghi dạng **text** `dd/mm/yyyy`, `HH:MM:SS` (tiền tố `'`), vì cột G/H của MB đang format `#,##0` và `Bill vô chủ` đang lưu text; ghi ISO sẽ hiện thành số serial. Muốn ngày thật: đổi định dạng cột G/H trong sheet rồi sửa `date_text` trong writer.

**Chống formula injection.** Mọi ô chữ lấy từ OCR/admin (tên đại lý, HKD, remitter, `raw_merchant_name`) bắt đầu bằng `= + - @` được ghi với tiền tố `'`.

**Tạo `DS MB T{n}`.** Nhân bản sheet tháng lớn nhất thành `__setup_DS MB T{n}`, đặt lại ngày và xoá số, rồi mới đổi tên thành `DS MB T{n}`; lỗi giữa chừng không để lại sheet tháng dở, lần retry xoá sheet tạm và làm lại. Cột ngày là các dãy ≥ 5 ngày liên tiếp; chỉ ô **số** (không phải công thức) dưới cột ngày bị xoá, bằng `""` (Sheets bỏ qua `null`). Đọc bằng `FORMULA` để không đụng các ô `=sum(...)`. Tháng ít ngày hơn: ô ngày thừa để trống; tháng nhiều ngày hơn dùng lại hàng trống dưới bảng.

**Tìm hàng ngày.** Chỉ trong dãy ngày liên tiếp của đúng bảng; không trượt sang bảng bên dưới. Thiếu ngày → `ds_cell_missing` → `Bill vô chủ`.

**Admin.** Form agent có ô `ds_sheet_anchor` (đúng chữ góc trái bảng trong DS MB) và bắt buộc nhập, không còn mặc định theo tên merchant. `tid_key` nhập `1` thành `tid1`. Xoá dealer đang gắn HKD bị chặn (`restrict_with_error`).

**Lưu ý template.** Công thức tổng trong `DS MB T10` đang là `=sum(B1:B30)` (và `B40:B69` cho bảng dưới), trong khi dữ liệu chạy đến hàng 32 (và 70): ngày 30 và 31 không được cộng vào tổng. Sửa trong sheet, code không đổi công thức.

**Ticket (chưa làm).** Tên sheet kèm năm (va chạm ngày 9/2027; deadline xử lý 8/2027). Nút ghi lại (resync) trong admin. Cảnh báo UI khi reject hoặc đổi số tiền của giao dịch đã ghi sheet ("đã ghi vào `DS MB T10!B2`, trừ tay 486.000").

## 16. Checklist deploy pha 2

1. Snapshot (pg_dump) hai cột `merchants.dealer_id` và `telegram_chats.dealer_id` trước khi chạy migration; `down` chỉ tạo lại cột rỗng.
2. Chạy `Workbook::Seed.call` và tạo `merchant_dealers` cho **mọi** merchant đang hoạt động (ds_sheet_anchor = chữ trong DS MB). Merchant thiếu mapping sẽ vào `needs_review` với `dealer_unmapped`.
3. Fee rule gắn dealer: kiểm tra vẫn khớp với dealer theo TID.
4. Spreadsheet là Google Sheet native, đã share quyền Editor cho service account; có `HELLO_SMC_SPREADSHEET_ID` và `GOOGLE_SHEETS_CREDENTIALS_*`.
5. Sheet `MB` cột L và `Bill vô chủ` cột G dành cho marker, không dùng cho việc khác.

## 17. Tên nhóm Telegram `TenDaiLy-HKD1-HKD2` (11/10/2026)

- Mẫu tên nhóm: `TenDaiLy-HKD1[-HKD2]`. `Telegram::ChatNameParser` chỉ tách chuỗi; `TelegramChat#group_dealer` khớp phần đầu với `Dealer` active theo tên (không phân biệt hoa/dấu) hoặc mã, **chỉ khi khớp đúng 1** (không đoán).
- Nhóm chọn được **nhiều HKD** qua bảng nối `telegram_chat_merchants` (thay `telegram_chats.merchant_id`, có backfill). Admin chọn là nguồn đúng; tên nhóm chỉ gợi ý (`name_merchants`). Nhóm chưa chọn HKD thì không bị giới hạn.
- `merchant_dealers` (HKD + đại lý + TID) là bảng mapping TenDaiLy ↔ TID. `Dealers::Resolver` (dùng chung cho Evaluator và `Workbook::Resolver`):
  - có đại lý theo tên nhóm + TID trên bill: TID phải thuộc đúng đại lý đó, nếu TID thuộc đại lý khác → `dealer_group_mismatch` (workbook: `agent_group_mismatch`), không tự gán.
  - có đại lý theo tên nhóm, bill không có TID: dùng khi (HKD, đại lý) chỉ có đúng 1 dòng mapping.
  - tên nhóm không nhận ra đại lý: giữ hành vi cũ, chỉ theo TID.
- HKD trên bill không nằm trong danh sách HKD của nhóm → `merchant_not_in_chat` → `needs_review`.
- Fallback HKD của `Workbook::Resolver` chỉ dùng khi nhóm có đúng 1 HKD.
- Deploy: chạy migration `20261011120000_create_telegram_chat_merchants` (backfill HKD cũ), rồi đổi tên các nhóm theo mẫu.
- UI admin (Nhóm Telegram → Thêm/Sửa): ô "Hộ kinh doanh" là dropdown tick nhiều HKD (dùng lại partial `admin/fee_rules/_choice_dropdown` với `param_prefix: "telegram_chat"`). Nếu tên nhóm nhắc tới HKD đã cấu hình thì form hiện gợi ý, không tự tick. Trang danh sách/chi tiết hiện cột "Đại lý (theo tên nhóm)" và danh sách HKD.
- Spec: `spec/services/telegram/chat_name_parser_spec.rb`, `spec/models/telegram_chat_spec.rb`, `spec/services/dealers/resolver_spec.rb` (khối "Telegram group title"), `spec/services/workbook/resolver_spec.rb`, `spec/services/transactions/builder_spec.rb` ("Telegram group HKD list"), `spec/requests/telegram_chats_spec.rb`, `spec/services/transactions/cherry_cofee_bill_spec.rb`.

## 18. Báo cáo người đi tiền: tab `thu chi {ngày}{tháng}` (thay `R&D Report`, 11/10/2026)

> **Đã thay bằng `SPEC_REMITTER_TRANSFER_CODE.md`:** transaction không còn ghi tab `thu chi` và cột K tab MB; tab `thu chi` được ghi từ lệnh chuyển tiền (mỗi lệnh chèn một hàng). DS MB nay cộng dồn dạng công thức `=a+b`. Phần dưới chỉ còn đúng cho cách tìm khối/cột.

File chuẩn không còn sheet `R&D Report`; mỗi ngày một tab `thu chi 1010` (không đệm số 0: `thu chi 910`).
- Tab theo ngày của `transaction_at` (múi giờ VN). Hàng 2 lặp tên người đi tiền theo từng khối; nhãn đại lý nằm ở cột trống ngay trước tên người đi tiền (động, không cố định cột A/G/M, không giới hạn 5 người).
- Nhãn đại lý so khớp theo tên: bỏ phần kênh trong ngoặc hoặc `MB/SP/QR` ở cuối, không phân biệt hoa/dấu/khoảng trắng; chỉ tìm từ hàng 3 đến trước vùng sổ quỹ thủ công (`SP in`, `TOTAL AMOUNT`) để tên như `Lập`, `An` không khớp nhầm tiêu đề `LẬP`, `AN`.
- Số tiền ghi vào **ô trống đầu tiên** của cột người đi tiền trong khối (từ hàng nhãn đến trước hàng `TOTAL`, không ghi vào hàng đệm sát `TOTAL` vì chưa rõ công thức `SUM` có phủ hay không). Không cộng dồn vào một ô.
- Không đặt được thì chỉ bỏ phần báo cáo (DS MB và MB vẫn ghi), `workbook_entries.payload.issue` là một trong: `rd_sheet_missing` (chưa có tab của ngày), `rd_agent_missing`, `rd_remitter_missing`, `rd_total_missing`, `rd_block_full` (hết hàng trống, cần người chèn hàng).
- Tab ghi được lưu ở `payload.rd_sheet`, ô ở `rd_cell`. Không tự tạo tab ngày.
- `rd_agent_label` phải khớp nhãn thật trong tab; seed hiện có vài nhãn không khớp (`Anh Hải`, `Anh Thọ`, `Chị Mến`, `Tuân`) cần sửa trong admin.
- **Người đi tiền mới** (có trong admin nhưng chưa có cột ở tab của ngày): sau khi tìm được khối đại lý, hệ thống chèn một cột cuối mỗi khối chưa có tên đó (xử lý khối bên phải trước), ghi tên vào hàng 2, copy định dạng cột bên trái và copy công thức ở các hàng `TOTAL` của cột bên cạnh (dịch 1 cột), rồi ghi số tiền. Chỉ dịch các hàng của vùng khối (`insertRange`, không phải chèn cả cột), nên sổ quỹ thủ công ở dưới không bị đẩy. Chỉ chèn ở tab của ngày giao dịch; tab ngày khác thêm cột khi có giao dịch ngày đó (hoặc người dùng tự thêm). Chèn một lần: lần sau thấy tên ở hàng 2 thì không chèn nữa.
- Lưu ý: `excel_key` gõ sai trong admin sẽ chèn một cột sai vào tab thật; sửa `excel_key` và xóa cột thừa bằng tay. Bảng tổng hợp ở cuối tab (`TOTAL AMOUNT`, `REMAINING BALANCE`) không tự thêm người mới, cần thêm tay.

## Điều kiện ghi: chỉ transaction đã duyệt

`HelloSmcWriter` chỉ ghi khi `transaction.finalized?` (`approved` hoặc `exported`); trạng thái khác trả `:skipped_not_approved` (cùng `skipped_failed`, `skipped_rejected`, `skipped_no_amount`, `skipped_no_date`). Job được enqueue ở hai chỗ: `Transactions::Builder` khi tự duyệt (auto-approve) và `Transactions::Approver` khi người duyệt bấm duyệt (kể cả từ `hold`). Transaction `needs_review`/`hold` không đụng sheet, kể cả tab `Bill vô chủ`. Transaction đã duyệt từ trước khi áp dụng rule này và chưa ghi: enqueue lại `WriteHelloSmcWorkbookJob.perform_later(id)`.

## Người nhận chuyển khoản → gợi ý đại lý

OCR đọc thêm `recipient_name` (chủ tài khoản nhận) chỉ với `document_type = transfer`; trường này nằm ngoài `Prompt::FIELDS` nên không có confidence, không critical, và run cũ không có trường này vẫn hợp lệ. `Dealers::Resolver` so tên người nhận (bỏ dấu, theo từng từ nguyên vẹn, ví dụ `TRAN NGUYEN KHANH SON` ↔ đại lý `Sơn`) với các đại lý đang active của HKD; chỉ khi đúng một đại lý khớp mới có gợi ý.
- Gợi ý không bao giờ ghi đè: TID hoặc tên nhóm đã xác định đại lý khác → `dealer_recipient_mismatch` (workbook: `agent_recipient_mismatch`, vào `Bill vô chủ`/review).
- Bill không có TID, tên nhóm không nêu đại lý nào khác, và đại lý đó chỉ có đúng một dòng TID trong HKD → resolve với `source = recipient`. Có nhiều dòng TID thì vẫn `dealer_unmapped`.
- TID có trên bill nhưng chưa map → vẫn `dealer_unmapped`, người nhận không thay thế.

## Độ bền khi ghi sheet (review kỹ thuật)

- **Retry:** `WriteHelloSmcWorkbookJob` retry 200 lần khi lock bận, tối đa 12 lần (chờ tăng dần, trần 5 phút) với lỗi quota 429, 5xx và lỗi mạng của Google; các lỗi Google khác 5 lần.
- **Lưới an toàn:** `RetryWorkbookWritesJob` (`bin/rails hellosmc:retry_workbook_writes`, lên lịch ~10 phút/lần) enqueue lại mọi transaction `approved`/`exported` có số tiền, ngày giờ mà chưa có `WorkbookEntry` và `updated_at` quá 15 phút, tối đa 200 cái mỗi lượt, giãn 2 giây. Ghi lại là an toàn nhờ marker `TX<id>` và advisory lock.
- **Hạn mức Google:** metadata sheet được cache trong một lần ghi (xoá sau mỗi thay đổi cấu trúc) để bớt số lần đọc. Còn có thể gộp đọc MB/DS/thu chi bằng `values.batchGet` và chỉ đọc phần đuôi của MB.
- **Enqueue:** `Builder` chỉ enqueue sau khi DB commit (`ActiveRecord.after_all_transactions_commit`).
- **Đại lý suy ra từ người nhận:** luôn kèm lý do review `dealer_from_recipient`, không tự duyệt.
- **Deploy migration `create_telegram_chat_merchants`:** chạy `db:migrate` rồi restart web/Sidekiq ngay (hoặc dừng nhận webhook trong lúc đó), vì migration bỏ cột `telegram_chats.merchant_id` mà code cũ còn đọc. `down` chỉ giữ HKD đầu tiên của mỗi nhóm.
