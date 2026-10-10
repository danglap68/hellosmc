# Spec: ghi giao dịch vào Google Sheet Hello SMC khi tạo transaction

Trạng thái: chưa implement. Album để sau. File này là hợp đồng cho việc tự điền **Google Sheet** (bản clone từ `Hello SMC.xlsx`) sau khi OCR tạo giao dịch.

Mẫu bố cục (chỉ để đọc khi viết spec/seed, **không ghi**): `/Users/ducnguyen/Documents/work/hellosmc/Hello SMC.xlsx` (đọc ngày 10/10/2026). Bản sống là Google Sheet. Tên tab phải giữ nguyên tên sheet trong file gốc.

| Tên trong yêu cầu | Tên sheet thật |
|---|---|
| Bill_No_Customer | `Bill vô chủ` |
| R & D / R & D Report | `R&D Report` |
| DS MB T10 | `DS MB T10` |
| MB | `MB` |

Sheet khác trong file, **không đụng** lần này: `Bản sao của R&D Report`, `DS MB T9`, `DS SP T10`.

## 1. Mục tiêu

Khi `Transactions::Builder` tạo một giao dịch từ bill đã OCR, hệ thống ghi **online** vào một Google Sheet (ID cấu hình). Sheets API đọc/ghi ô tại chỗ. Không tải `.xlsx` về, không upload đè, không chờ màn Xuất Excel.

Ba nhánh:

1. **Không xác định được HKD hoặc không xác định được đại lý (agent)** → thêm một dòng vào `Bill vô chủ`. Không ghi `R&D Report`, không ghi `DS MB T{tháng}`, không ghi `MB`.
2. **Đã có HKD + đại lý** → cộng dồn ô ngày trên `DS MB T{tháng}` và thêm một dòng vào `MB`.
3. **Đã có HKD + đại lý + người chuyển tiền (remitter)** → thêm bước cộng dồn ô remitter trên `R&D Report`.

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

### 3.2 `R&D Report`

Lưới khối đại lý. Hàng 2 lặp năm remitter: `LẬP`, `KIM`, `AN`, `YẾN`, `CÔ TUYẾT`.

Mỗi đại lý chiếm một khối ~9 hàng nhập + 1 hàng `TOTAL` (`=SUM`). Nhãn đại lý ở cột A / G / M, có kênh `(MB+SP)` chỉ để người đọc, không dùng để chọn ô.

Ví dụ Chương: nhãn `G23` = `Chương (MB+SP)`. Cột remitter của khối này là H–L. **H23 = LẬP của Chương** — đúng ô trong ví dụ.

`R&D Report` **không** là công thức kéo từ `DS MB T10`. Hai sheet khác hạt: `DS MB` theo (HKD, đại lý, ngày); `R&D` theo (đại lý, remitter). Cùng một giao dịch ghi cả hai. Tổng remitter của một đại lý trên `R&D` về lý thuyết khớp tổng tháng của đại lý đó trên mọi bảng `DS MB T{tháng}` (cộng mọi HKD). Không bắt Excel `SUM` chéo sheet.

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
| `rd_agent_label` | Nhãn khối `R&D Report` (`Chương`) |
| `active` | |

Unique `(merchant_id, dealer_id, tid_key)`. Unique `(merchant_id, tid_key)` trong các dòng active: một TID dưới một HKD chỉ một đại lý.

**`remitters`:**

| Cột | Ý nghĩa |
|---|---|
| `name` | `Lập`, `Kim`, `An`, `Yến`, `Cô Tuyết` |
| `excel_key` | `LẬP`, `KIM`, `AN`, `YẾN`, `CÔ TUYẾT` — khớp hàng 2 `R&D Report` |
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
| `rd_cell` | ví dụ `H23`, null nếu không có remitter |
| `mb_row` | số hàng sheet `MB` |
| `unidentified_row` | số hàng `Bill vô chủ` |
| `amount_vnd` | số đã cộng |
| `payload` | jsonb: merchant, dealer, tid, remitter, ngày |

**Đổi quan hệ cũ:**

- `Merchant`: bỏ bắt buộc `dealer_id`. Giữ cột đến khi migrate xong, rồi nullify. `has_many :merchant_dealers`, `has_many :dealers, through: :merchant_dealers`.
- `TelegramChat`: thêm `merchant_id` (group = HKD). `dealer_id` không còn dùng để chọn đại lý. Chat unmapped → không suy ra HKD từ group.
- `TelegramMessage`: thêm `telegram_username` (lấy `from.username`). Đã có `telegram_sender_id`.
- `Dealers::Resolver`: không còn “chat → dealer”. Đại lý lấy từ TID / tên bill. HKD: OCR merchant, rồi fallback chat.`merchant`.

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

Merchant trong app hiện có (`001_ HỘ KINH DOANH THIÊN KIM GV`, `HKD AS CAFE-CAFE 96-2`, …) map sang header bằng alias / `normalized_name`, không tạo bản ghi trùng nếu đã khớp.

`rd_agent_label` map tay trong seed khi tên R&D khác DS MB (`NamHai` vs `Hải`, `PCuong` vs `PHÙNG CUỜNG`, `HiêuSG` vs `Anh Hiếu`). Spec test bắt buộc có map cho Chương, Sơn, Hải / NamHai.

## 5. Cách chọn HKD, đại lý, remitter

Thứ tự sau OCR, trong service mới `Workbook::Resolver` (không nhét vào `FeeRules::Resolver`):

```
HKD:
  1. Merchants::Resolver (tên / MID trên bill) như hiện tại
  2. Nếu không ra: telegram_chat.merchant
  3. Vẫn không ra: unidentified

Đại lý (chỉ khi đã có HKD):
  1. TID / hậu tố trên tên merchant OCR: "... GV-1", "tid1", "TID 127"
  2. Tra merchant_dealers của HKD đó theo tid_key
  3. Không ra: unidentified (dù đã có HKD)

Remitter:
  1. telegram_sender_id = remitters.telegram_user_id
  2. telegram_username (không phân biệt hoa thường) = remitters.telegram_username
  3. Không ra: remitter = null. Vẫn ghi DS MB + MB nếu đã có HKD+đại lý. Không cộng R&D.
```

Ví dụ trong yêu cầu: group HKD Thiên Kim GV, người gửi Lập (`telegram_user_id` sau này = 1234567890), bill hiện `HỘ KINH DOANH THIÊN KIM GV-1` → HKD Thiên Kim GV, `tid1` → Chương, remitter Lập.

Chưa map remitter thì bước R&D bỏ qua, hai sheet kia vẫn ghi.

## 6. Khi nào ghi

Sau `Transactions::Builder#finish` khi giao dịch vừa tạo hoặc vừa rebuild từ `processing`. Job `WriteHelloSmcWorkbookJob` (queue `exports`), không ghi trong request Telegram.

Không ghi lại nếu đã có `workbook_entries` cho `transaction_id` (trừ khi rebuild và entry bị xóa tay).

Giao dịch `failed` / OCR fail: không ghi. `needs_review` vẫn ghi nếu đã có số tiền và (nhánh unidentified hoặc identified). Bill vô chủ chính là chỗ chứa review thiếu HKD/đại lý.

Số cộng dồn: `transaction_amount_vnd` (số trên bill), không dùng tiền sau phí gốc. Các ô ngày trên `DS MB T10` hiện đang là số giao dịch gốc.

## 7. Ghi Google Sheet

Nguồn sống: một spreadsheet native (đã File → Save as Google Sheets / convert khi upload). URL dạng `https://docs.google.com/spreadsheets/d/{SPREADSHEET_ID}/edit`. Setting `hello_smc_spreadsheet_id`. Thiếu ID hoặc sheet chưa share cho service account → job fail, retry, không im lặng.

**Auth.** Service account, scope `https://www.googleapis.com/auth/spreadsheets`. Share spreadsheet cho email service account, quyền Editor. Không dùng OAuth user cho job nền.

**Gem.** `google-apis-sheets_v4`. Không cần Drive API nếu đã có spreadsheet ID.

**Client.** `Workbook::GoogleSheetClient`: `get_values(range)`, `update_values(range, values)`, `append_values(range, values)`, `duplicate_sheet(source_title:, dest_title:)`, `sheet_titles`. Test stub client này, không gọi mạng.

**Khóa ghi.** Advisory lock Postgres theo `spreadsheet_id` trong job (tránh hai giao dịch đọc-cộng-ghi cùng ô). Google không lock ô; app phải serialize.

**Một lần ghi.** Đọc các ô cần cộng → tính số mới → `values.batchUpdate` mọi ô/hàng của giao dịch đó (DS MB + R&D + MB, hoặc chỉ Bill vô chủ) → mới tạo `workbook_entries`. Fail giữa chừng: không tạo entry, job retry. Retry phải idempotent: đã có entry thì dừng.

### 7.1 `DS MB T{tháng}`

### 7.1 `DS MB T{tháng}`

`tháng` = tháng của `transaction_at` (timezone app). Tên sheet `DS MB T10`, `DS MB T11`, không zero-pad hai chữ số nếu tháng < 10? File đang dùng `T9` và `T10` → **`DS MB T#{month}`** không pad (`T9`, không `T09`).

Không có sheet:

1. `spreadsheets.batchUpdate` `DuplicateSheet` từ tab `DS MB T*` có số tháng lớn nhất.
2. Đổi title thành `DS MB T{tháng mới}`.
3. Đổi cột ngày thành 1…cuối tháng mới (timezone app).
4. Xóa số tiền các ô ngày (để trống), giữ công thức `=SUM`.

Tìm bảng: hàng header có ô = `ds_sheet_anchor` của `merchant_dealers`. Trong các cột của bảng đó, header khớp `ds_header` (chuẩn hóa khoảng trắng). Hàng ngày = ô ngày cùng `transaction_at.to_date`.

Cộng: `ô = (ô.to_f) + amount`. Ghi **số**, không ghi `=cũ+mới` (file đang dùng số; `SUM` cuối bảng là công thức cần giữ).

Không tìm được sheet / bảng / cột / hàng ngày → không đoán. Ghi `Bill vô chủ` và `workbook_entries.branch = unidentified` kèm lý do `ds_cell_missing`.

### 7.2 `R&D Report`

Chỉ khi có remitter.

Tìm khối: ô nhãn đại lý (cột A/G/M) chứa `rd_agent_label` (so khớp không dấu, bỏ dòng `(MB+SP)`). Cột remitter = cột trong cùng khối có hàng 2 = `excel_key`. Ô ghi = cột đó, **hàng đầu của khối** (H23 cho Lập–Chương).

Cộng số vào ô đó, giữ hàng `TOTAL` = `SUM`.

Không tìm thấy khối / cột → không cộng R&D, vẫn ghi DS MB + MB, ghi `rd_cell_missing` vào payload. Không chuyển sang Bill vô chủ.

### 7.3 `MB`

Hàng trống đầu tiên ở cột A. Điền A, D, F–K. Sửa C (và E nếu cần) theo `base_fee_rate_used`: `0.0088` → `0.88%`, `0.0121` → `1.21%`. Không đụng hàng đã có A.

Hết 1000 hàng: thêm hàng mới, copy công thức B/C/E từ hàng trên.

### 7.4 `Bill vô chủ`

Hàng trống đầu tiên. A = tên OCR hoặc `—`. C = `transaction_amount_vnd`. D = `base_fee_rate_used` hoặc 0.0088 nếu chưa tính. E = `transaction_at`. F = `Thành công` nếu approved, không thì `Cần kiểm tra`. B giữ/ghi `=C{n}-(C{n}*D{n})`.

## 8. Admin

- CRUD remitter: tên, excel_key, telegram_user_id, telegram_username.
- Form HKD: tick nhiều đại lý, mỗi dòng một TID + header DS MB + nhãn R&D.
- Form group Telegram: chọn HKD (`merchant_id`), bỏ bắt buộc đại lý.
- Trang giao dịch: hiện remitter, tid, ô đã ghi (`ds_cell`, `rd_cell`, `mb_row`) nếu có entry.

## 9. Ví dụ chốt (Lập → Chương tid1, 01/10/2026)

Bill 486.000, HKD Thiên Kim GV, tid1, remitter Lập (sau khi đã map).

| Sheet | Ô / hàng | Trước | Sau |
|---|---|---|---|
| `DS MB T10` | B2 (01/10, Chương tid1) | 354.367.000 | 354.853.000 |
| `R&D Report` | H23 (Chương × LẬP) | (trống hoặc số cũ) | cũ + 486.000 |
| `MB` | hàng A trống đầu tiên | A trống | A=486000, I=Chương, J=Thiên Kim GV, K=Lập |
| `Bill vô chủ` | — | không thêm | |

Thiếu map remitter: B2 và MB vẫn ghi, H23 không đổi.

Thiếu HKD hoặc tid: chỉ `Bill vô chủ`.

## 10. Rủi ro và điểm mở

1. **Phải là Google Sheet native.** File `.xlsx` chỉ nằm trên Drive thì API Sheets không ghi tab được. Phải convert / “Save as Google Sheets”.
2. **Share service account.** Quên share → 403. Job fail có log, giao dịch vẫn còn.
3. **Quota.** Sheets API khoảng 60 ghi/phút/project. Mỗi giao dịch một `batchUpdate`. Hai job cùng ô: advisory lock trong app.
4. **Cộng hai lần.** `workbook_entries.transaction_id` unique. Rebuild không ghi lại trừ khi xóa entry.
5. **R&D không SUM từ DS MB.** Hai tab ghi độc lập. `batchUpdate` một lần cho cả giao dịch để khỏi lệch giữa chừng.
6. **TID trên OCR.** Parser (`-1`, `tid1`, `TID 127`). Không đoán khi tên không có hậu tố.
7. **Nhãn R&D ≠ header DS MB** (`Hải` vs `NamHai`). Seed phải có `rd_agent_label`.
8. **Tháng mới.** `DuplicateSheet`; sai header thì T11 hỏng. Test tạo T11 từ T10 (stub API).
9. **Chị Huệ ba TID** (127/128/129) cùng người, ba cột. Không gộp.
10. **Secret.** Không commit JSON service account. Không đưa spreadsheet ID vào spec hay git nếu coi là nội bộ — để ENV.

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

### 11.6 R&D Report

- Lập + Chương → H23 tăng, I23–L23 không đổi, `=SUM(H23:H31)` giữ.
- Kim + Chương → I23, không phải H23.
- Identified nhưng remitter nil → không đổi R&D.
- Không tìm thấy nhãn R&D → DS MB + MB vẫn ghi.

### 11.7 MB

- Hàng trống đầu tiên: A = amount, D = dealer rate, I/J/K đúng, C dùng `0.88%` khi `base_fee_rate_used` là 0,88%.
- Không ghi đè hàng đã có A.
- Có cột K người đi tiền.

### 11.8 Bill vô chủ

- Thiếu HKD hoặc thiếu tid: thêm một dòng, không đổi T10 / R&D / MB.
- Identified: không thêm dòng.

### 11.9 Builder / job

- `Builder` enqueue `WriteHelloSmcWorkbookJob` sau khi tạo giao dịch có số tiền.
- OCR failed: không enqueue.
- Thiếu `hello_smc_spreadsheet_id` hoặc API 403/404: job fail có log, giao dịch vẫn tồn tại, không có `workbook_entries`.
- Client Sheets được stub; spec không gọi Google thật.

### 11.10 Parser TID

- `HỘ KINH DOANH THIÊN KIM GV-1` → `tid1`.
- `Chị Huệ (TID 127)` / `TID 127` trên tên → `tid127`.
- Không hậu tố → nil.

## 12. Thứ tự implement

1. Migration `remitters`, `merchant_dealers`, `workbook_entries`; `telegram_chats.merchant_id`; `telegram_messages.telegram_username`.
2. Seed 5 remitter + script/seed `merchant_dealers` từ mẫu `DS MB T10` (xlsx hoặc dump đã chốt ở mục 4.3).
3. `Remitters::Resolver`, `Workbook::TidParser`, `Workbook::Resolver`.
4. `Workbook::GoogleSheetClient` + `Workbook::HelloSmcWriter` (cộng DS MB, cộng R&D, append MB, append Bill vô chủ, `DuplicateSheet` T{n+1}).
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
| 4 | Thiếu remitter: vẫn ghi DS MB + MB, bỏ R&D. |
| 5 | Thiếu HKD hoặc thiếu đại lý: chỉ `Bill vô chủ`. |
| 6 | Group Telegram = HKD, không phải đại lý. Đại lý = TID. |
| 7 | Ghi lúc tạo giao dịch (job), không lúc xuất Excel. |
| 8 | Một giao dịch chỉ ghi workbook một lần (`workbook_entries`). |
| 9 | Tháng mới: `DuplicateSheet` tab `DS MB T*` mới nhất, đổi ngày. |
| 10 | Album không làm trong spec này. |
| 11 | Bản sống là Google Sheet. Ghi bằng Sheets API. Không ghi `.xlsx` trên disk hay upload đè file Drive. |
