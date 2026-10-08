# Spec: thêm loại xuất Excel Kết toán theo phí gốc, giữ file xuất hiện tại

Trạng thái: đã implement. File này là hợp đồng cho nhánh `auto-fill-transaction-data`.

Mẫu đối chiếu: `/Users/ducnguyen/Downloads/SMC-dien-20261005.xlsx` (copy của `MB 2th10.xlsx`, đã điền một dòng mẫu ở sheet `1,21`). Tên `SMC-dien` chỉ là tên file mẫu cũ, không dùng cho file xuất.

## 1. Mục tiêu

Màn `/admin/excel_exports/new` tạo một trong hai loại file. Tạo giao dịch không ghi Excel và không chọn sheet.

| Option **Loại file** | `excel_exports.layout` | File |
|---|---|---|
| File hiện tại | `legacy` | Giữ nguyên hai sheet `Giao dịch` và `Tổng hợp` |
| Kết toán theo phí gốc | `ket_toan_phi_goc` | Ba sheet `1,21`, `1,17`, `1,15`, cột và công thức như file mẫu |

Loại Kết toán theo phí gốc đọc giao dịch đã có trong database lúc bấm xuất. Một giao dịch thành một dòng trên đúng một sheet. Thẻ thường lấy sheet theo phí gốc đã chốt trên giao dịch. Thẻ MB hoặc Napas lấy sheet theo phí gốc của hộ, còn công thức và cột D lấy theo quy tắc của loại thẻ. Cột tiền và lợi nhuận là công thức Excel.

Cron `hellosmc:export_daily` vẫn chỉ tạo loại `legacy` cho ngày hôm qua. Không thêm nút trên dashboard **Tổng quan**.

## 2. Ngoài phạm vi

- Không ghi vào file Excel gốc trên máy kế toán. Vẫn tạo file mới, tải từ **Xuất Excel**.
- Không xóa, không đổi cột, sheet, hay cách đánh dấu đã xuất của loại `legacy`.
- Không thêm sheet `MBV`. Giao dịch không thuộc `1,21` / `1,17` / `1,15` thì không ghi vào file Kết toán theo phí gốc.
- Không thêm cột trạng thái, người đi tiền, số hóa đơn, bill con vào Kết toán theo phí gốc.
- Không đổi cách OCR, cách chọn fee rule, hay lịch cron `00:05`.
- Không đổi công thức trong `Transactions::Calculator`.
- Không gộp hai loại vào một workbook.
- Không chọn sheet và không ghi dòng Excel sau khi OCR xong hoặc sau khi tạo giao dịch.

## 3. Field loại file trên `/admin/excel_exports/new`

Form **Tạo file Excel** thêm một field **Loại file**, là một `select`, bắt buộc. Mặc định `legacy`. Không thêm nút trên **Tổng quan**.

| Giá trị | Nhãn |
|---|---|
| `legacy` | File hiện tại |
| `ket_toan_phi_goc` | Kết toán theo phí gốc |

Card **Các cột trong file** bên phải đổi ngay khi đổi option, không cần bấm tạo:

- `legacy`: danh sách cột hiện tại của `Exports::LegacyLayout`, kể cả cột không tên, và câu trạng thái Thành công / bill hold.
- `ket_toan_phi_goc`: cột A–J ở mục 5.1, kèm câu: giao dịch không thuộc ba mức phí gốc thì không có trong file.

**Từ ngày** và **Đến ngày** giữ như form hiện tại. Bấm **Tạo file Excel** gửi `layout` đã chọn, chạy `GenerateDailyExcelJob`, rồi vào trang chi tiết lần xuất để tải file.

Cột mới `excel_exports.layout`, `string`, `null: false`, default `legacy`. Check constraint chỉ nhận `legacy` và `ket_toan_phi_goc`. Bản ghi cũ sau migrate là `legacy`.

Danh sách lần xuất thêm cột **Loại file**. Trang chi tiết hiện nhãn loại. Bảng tổng hợp theo đại lý chỉ hiện khi `layout` là `legacy`. Kết toán theo phí gốc hiện số dòng bị bỏ, đọc `metadata["skipped"]`.

Tên file tải về. Giờ là lúc file được tạo, múi `Asia/Ho_Chi_Minh`, dạng `HHmmss`. Ngày là khoảng giao dịch trong file.

- `legacy`: giữ `smc-YYYYMMDD.xlsx`, hoặc `smc-YYYYMMDD-YYYYMMDD.xlsx` khi khoảng nhiều ngày.
- `ket_toan_phi_goc`: `smc-ket-toan-phi-goc-YYYYMMDD-HHmmss.xlsx`. Khoảng nhiều ngày: `smc-ket-toan-phi-goc-YYYYMMDD-YYYYMMDD-HHmmss.xlsx`.

Ví dụ xuất ngày `2026-10-05`, tạo lúc 23:57:04: `smc-ket-toan-phi-goc-20261005-235704.xlsx`. Hai lần xuất cùng một ngày không trùng tên.

Cùng một giao dịch được ghi vào cả hai loại nếu mỗi loại đều nhận dòng đó. `transactions.excel_export_id` trỏ lần xuất gần nhất đã ghi dòng. `source_data["export_ids"]` giữ mọi id. Dòng Kết toán theo phí gốc bị bỏ không đổi trạng thái, nên lần xuất `legacy` sau đó vẫn nhận dòng đó.

## 4. Quyết định về hai mức phí

Thẻ thường: tên sheet là đúng số nằm trong công thức cột C và cột E.

| Sheet | Công thức cột C | Công thức cột E |
|---|---|---|
| `1,21` | `=A{n}-(A{n}*1.21%)` | `=A{n}*(D{n}-1.21%)` |
| `1,17` | `=A{n}-(A{n}*1.17%)` | `=A{n}*(D{n}-1.17%)` |
| `1,15` | `=A{n}-(A{n}*1.15%)` | `=A{n}*(D{n}-1.15%)` |

Cột B mọi sheet, mọi loại thẻ: `=A{n}-(A{n}*D{n})`.

Thẻ thường đối chiếu với số đã chốt trên giao dịch:

| Ô admin | Cột DB trên giao dịch | Ô Excel |
|---|---|---|
| Phí gốc | `applied_base_fee_rate` | Phần trăm cứng trong cột C và cột E, đồng thời là tên sheet |
| Phí đại lý | `applied_dealer_rate` | Cột D |

Ví dụ thẻ thường của một hộ vào sheet `1,21` và cột D = 1,40%: quy tắc phí của hộ đó có **Phí gốc `1,21`**, **Phí đại lý `1,40`**, và giao dịch đã chốt hai số đó.

Thẻ `mb` hoặc `napas` dùng hai nguồn lúc xuất file. Snapshot trên giao dịch không đổi, và không được dùng cho sheet, cho phần trăm trong C/E, hay cho cột D.

| Việc | Nguồn |
|---|---|
| Tên sheet | Quy tắc đang hiệu lực của đúng hộ, loại thẻ để trống hoặc `normal`, phí gốc đúng `1,21` / `1,17` / `1,15` |
| Công thức cột C và E | `base_fee_rate` của quy tắc loại thẻ `mb` hoặc `napas` |
| Cột D | `dealer_rate` của cùng quy tắc loại thẻ đó |

Quy tắc loại thẻ phải còn hiệu lực tại `transaction_at`. Merchant và đại lý của quy tắc khớp giao dịch, hoặc để trống. Mức cụ thể nhất thắng: hộ + thẻ, rồi đại lý + thẻ, rồi chỉ loại thẻ. Cùng mức, cùng `priority`, nhiều hơn một quy tắc thì không ghi dòng.

Ví dụ hộ có phí gốc `1,21` và phí đại lý `1,40`. Quy tắc thẻ MB có phí gốc `0,88` và phí đại lý `1,20`. Giao dịch thẻ MB của hộ đó vẫn có thể đang chốt `1,21` và `1,40` trong database. File ghi dòng vào sheet `1,21`, cột C và E dùng `0.88%`, cột D là `0.012`. Sheet không được suy ra từ `0,88`.

## 4. File đích

Ba sheet, đúng thứ tự: `1,21`, `1,17`, `1,15`. Sheet không có dòng dữ liệu vẫn được tạo, chỉ có dòng tiêu đề.

### 4.1 Cột

Dòng 1, copy đúng chữ trong file mẫu. Cột C xuống dòng trong header:

`Số tiền sau khi trừ phí gốc` + dấu cách + xuống dòng + `(1,21% với thẻ thường, thẻ MB - 0,88%)`. Cả ba sheet dùng đúng câu này, giống file mẫu.

| Cột | Header | Ô dữ liệu | Nguồn |
|---|---|---|---|
| A | Số tiền giao dịch | số | `transaction_amount_vnd` |
| B | Số tiền đã khấu trừ cho đại lý | công thức | `=A{n}-(A{n}*D{n})` |
| C | (header ở trên) | công thức | `=A{n}-(A{n}*{phần trăm})` |
| D | Tỷ lệ | số | Thẻ thường: `applied_dealer_rate`. Thẻ `mb` / `napas`: `dealer_rate` của quy tắc loại thẻ |
| E | Lợi nhuận | công thức | `=A{n}*(D{n}-{phần trăm})` |
| F | Số Lô | chữ | `lot_number`, giữ số 0 đầu |
| G | Ngày giao dịch | ngày | phần ngày của `transaction_at`, giờ `Asia/Ho_Chi_Minh` |
| H | Giờ giao dịch | giờ | phần giờ của `transaction_at` |
| I | Tên đại lý | chữ | `dealer.name` |
| J | Tên HKD | chữ | `merchant.name` |

`{n}` là số dòng Excel. Với thẻ thường, `{phần trăm}` là `1.21%`, `1.17%`, hoặc `1.15%` theo sheet. Với `card_types.key` là `mb` hoặc `napas`, `{phần trăm}` là phí gốc của quy tắc loại thẻ đó, viết dạng `0.88%` khi quy tắc đang là 0,88%.

### 4.2 Định dạng

Khớp file mẫu `MB 2th10.xlsx`, sheet `1,21`:

- Font Times New Roman. Căn giữa, xuống dòng trong ô. Viền mỏng quanh ô dữ liệu. Dòng dữ liệu cao 21. Dòng tiêu đề cao 132,75, chữ đậm cỡ 15, viền dày.
- A: `"₫"#,##0`, cỡ 14.
- B và C: `"₫"#,##0_);[Red]("₫"#,##0)`, cỡ 14, đậm, màu đỏ. Số âm hiện trong ngoặc đỏ.
- D: `0.00%`, cỡ 14.
- E: cùng format tiền với B, cỡ 14, chữ đen thường. Số âm hiện trong ngoặc đỏ.
- F và I: chữ, cỡ 14.
- G: `mm-dd-yy`. H: `h:mm:ss`.
- J: chữ, cỡ 16, đậm, màu `FF40FF`.
- Dòng tổng A, B, C, E dùng `"₫"#,##0`, chữ đen thường. D giữ format phần trăm và không cộng.

### 4.3 Dòng tổng

Dòng ngay dưới dòng dữ liệu cuối:

- A, B, C, E: `=SUM(...)` của các dòng dữ liệu.
- D không cộng. File mẫu có `SUM` cột D; spec này bỏ, vì cộng các tỷ lệ không phải tổng tiền.
- F–J để trống.

Không tạo sẵn hàng chục dòng công thức trống như file mẫu. Chỉ viết dòng có giao dịch.

### 4.4 Thứ tự dòng

Trong mỗi sheet, sort `transaction_at` tăng dần, rồi `id` tăng dần.

## 5. Giao dịch nào được ghi

Giữ bộ lọc hiện tại của `Exports::ExcelGenerator#scope`:

- `transaction_at` nằm trong `export_date`..`end_date`, ngày theo `Asia/Ho_Chi_Minh`, tới hết `end_date`.
- `status` thuộc `approved`, `exported`, `hold`.

Thêm điều kiện để được ghi một dòng. So sánh phần trăm bằng `BigDecimal`, không dùng Float. Một tỷ lệ chỉ khớp khi nhân 100 đã đúng 2 chữ số thập phân: `0.012100` là 1,21. `0.01211` là 1,211 và không khớp.

Thẻ thường:

1. `applied_base_fee_rate` là `1.21`, `1.17`, hoặc `1.15`. Đó là sheet và là phần trăm trong cột C, E.
2. `applied_dealer_rate` có giá trị. Thiếu thì không ghi dòng, vì cột B và E sẽ thành lỗi Excel.

Thẻ `mb` hoặc `napas`:

1. Sheet lấy từ quy tắc đang hiệu lực của cùng merchant, không gắn loại thẻ hoặc gắn loại thẻ `normal`, có phí gốc `1.21` / `1.17` / `1.15`. Không tìm thấy, hoặc các quy tắc cùng mức trỏ hai sheet khác nhau, thì không ghi dòng.
2. Một quy tắc loại thẻ được chọn theo mục 4, phí gốc của quy tắc đó là mức phần trăm đúng 2 chữ số, và `dealer_rate` có giá trị. Thiếu một trong ba thì không ghi dòng.

Không ghi, và không chuyển sang `exported`:

- `needs_review`, `rejected`, `failed`, `pending`, `processing`.
- Thẻ thường có phí gốc ngoài ba mức sheet.
- Thẻ `mb` / `napas` không có sheet của hộ.
- Thiếu tỷ lệ cho cột D, thiếu `transaction_at`, thiếu `transaction_amount_vnd`.

Những dòng bị bỏ ghi vào `excel_exports.metadata["skipped"]`: mảng `{ "transaction_id", "reason" }`. `reason` là `sheet_unmapped` hoặc `dealer_rate_missing`.

`transaction_count` = số dòng đã ghi, không tính dòng bị bỏ.

`hold` vẫn được ghi nếu đủ điều kiện trên. File mới không có cột trạng thái, nên dòng hold trông giống dòng đã duyệt. Giữ hành vi cũ: hold không bị chuyển sang `exported`.

Giao dịch `approved` đã ghi vào file thì chuyển `exported` như hiện tại. Giao dịch bị bỏ không chuyển trạng thái.

## 6. Solution

`Exports::ExcelGenerator` đọc `excel_export.layout` rồi dựng đúng một workbook.

- `legacy`: giữ `Exports::LegacyLayout` và hai sheet hiện tại. Tên file giữ nguyên.
- `ket_toan_phi_goc`: `Exports::KetToanPhiGocLayout` viết ba sheet. Chỉ ghi A, D, F, G, H, I, J và công thức B, C, E. Ghi `metadata["skipped"]`. `transaction_count` chỉ đếm dòng đã ghi. Không `mark_exported` dòng bị bỏ.

Giữ khóa dòng, Active Storage, `mark_exported` cho dòng đã ghi, và audit `export.generated`.

`ExcelExport#filename` nhận layout và giờ tạo. Form `/admin/excel_exports/new` gửi `layout`. Cron không gửi layout, nên bản ghi lịch vẫn là `legacy`.

## 7. Tasks

1. Migration thêm `excel_exports.layout`, default `legacy`, check `legacy` hoặc `ket_toan_phi_goc`.
2. Viết `Exports::KetToanPhiGocLayout`: hằng sheet, header, chọn sheet, công thức. Chưa đụng generator.
3. Spec layout: map phí gốc sang sheet, map MB/Napas `0.88%` sang sheet cha, `nil` khi không map được, công thức đúng số dòng.
4. `ExcelGenerator#build_workbook` rẽ theo layout. Layout `legacy` giữ test hiện tại.
5. Tên file `ket_toan_phi_goc` có ngày khoảng xuất và giờ tạo.
6. Field **Loại file** trên `/admin/excel_exports/new`. Card cột đổi theo option đang chọn. Danh sách và trang chi tiết hiện loại file. Locale nhãn **Kết toán theo phí gốc**. Không sửa dashboard.
7. Chạy `spec/services/exports` và `spec/system/transaction_approval_spec.rb`. Spec form mới: đổi option thì danh sách cột đổi; gửi **Kết toán theo phí gốc** thì `layout` là `ket_toan_phi_goc`. `transaction_approval_spec` không chọn field mới, vẫn tạo `legacy`.

## 8. Test case

Số tiền dùng trong test phải là số nguyên VND. Kỳ vọng cột B, C, E là chuỗi công thức, không phải số đã nhân sẵn. Roo đọc công thức được thì assert chuỗi. Không có Roo formula thì đọc XML của xlsx.

### 8.1 Chọn sheet

| Phí gốc đã áp trên giao dịch | Loại thẻ | Kết quả |
|---|---|---|
| 1,21% | normal | sheet `1,21`, C/E dùng `1.21%`, D = `applied_dealer_rate` |
| 1,17% | normal | sheet `1,17` |
| 1,15% | normal | sheet `1,15` |
| 1,21% (snapshot của hộ) | mb, hộ có quy tắc 1,21, quy tắc thẻ MB là 0,88 và 1,20 | sheet `1,21`, C/E dùng `0.88%`, D = `0.012` |
| 1,17% | napas, hộ có quy tắc normal 1,15, quy tắc Napas là 0,88 và 1,20 | sheet `1,15`, C/E dùng `0.88%`, D = `0.012` |
| 1,21% | mb, hộ không có quy tắc 1,21/1,17/1,15 | không ghi, `sheet_unmapped` |
| 1,21% | mb, hộ có sheet, quy tắc thẻ MB không có `dealer_rate` | không ghi, `dealer_rate_missing` |
| 0,88% | normal | không ghi, `sheet_unmapped` |
| 1,10% hoặc 1,25% | normal | không ghi, `sheet_unmapped` |
| 1,21% | normal, `applied_dealer_rate` nil | không ghi, `dealer_rate_missing` |

`1.210000%` và `1.21%` là cùng sheet. `1.211%` là `sheet_unmapped`.

### 8.2 Một dòng trên sheet `1,21`

Giao dịch: số tiền `190001000`, phí gốc `0.0121`, phí đại lý `0.014`, lô `"000038"`, `transaction_at` `2026-10-05 09:49:22 +0700`, đại lý `Anh Trân`, HKD `HKD AS CAFE-CAFE 96-2`, loại thẻ `normal`, status `approved`.

Dòng 2 sheet `1,21`:

| Ô | Kỳ vọng |
|---|---|
| A | `190001000` |
| B | `=A2-(A2*D2)` |
| C | `=A2-(A2*1.21%)` |
| D | `0.014` |
| E | `=A2*(D2-1.21%)` |
| F | text `000038` |
| G | `2026-10-05` |
| H | `09:49:22` |
| I | `Anh Trân` |
| J | `HKD AS CAFE-CAFE 96-2` |

Mở bằng Excel, giá trị tính ra: B = `187340986`, C = `187701987.9` làm tròn theo format tiền của file, E = `361001.9`. Spec không assert số làm tròn của Excel. Assert công thức.

Hai sheet kia chỉ có header.

### 8.3 Nhiều sheet trong một file

Ba giao dịch cùng ngày, phí gốc lần lượt 1,21%, 1,17%, 1,15%, đều có phí đại lý. Mỗi sheet đúng một dòng dữ liệu. `transaction_count` = 3. Cả ba `approved` chuyển `exported`.

### 8.4 MB nằm trên sheet của hộ, tính theo quy tắc thẻ

Hộ có quy tắc không gắn loại thẻ, phí gốc 1,21%, phí đại lý 1,40%. Quy tắc chỉ loại thẻ `mb` có phí gốc 0,88%, phí đại lý 1,20%. Giao dịch loại thẻ `mb` đang chốt phí gốc 1,21% và phí đại lý 1,40%, vì quy tắc của hộ thắng lúc duyệt.

Dòng nằm trên sheet `1,21`. C = `=A2-(A2*0.88%)`. E = `=A2*(D2-0.88%)`. D = `0.012`. Sau khi xuất, giao dịch vẫn giữ `applied_base_fee_rate` `0.0121` và `applied_dealer_rate` `0.014`.

Quy tắc hộ + thẻ MB, nếu có và còn hiệu lực, được dùng thay cho quy tắc chỉ loại thẻ. Sheet vẫn lấy từ quy tắc phí gốc của hộ.

### 8.5 Bộ lọc ngày và trạng thái

Giữ các case đang có trong `excel_generator_spec`:

- Giao dịch ngày khác khoảng export không được ghi.
- Giao dịch `needs_review` không được ghi và không sang `exported`.
- `approved` trong khoảng thì sang `exported`, gắn `excel_export_id`.
- `hold` trong khoảng, nếu đủ phí, thì được ghi và vẫn là `hold`.

Thêm:

- Giao dịch `approved` nhưng `sheet_unmapped` vẫn `approved`, có mặt trong `metadata["skipped"]`.
- Audit `export.generated` chỉ liệt kê id đã ghi.

### 8.6 Dòng tổng

Hai dòng trên cùng sheet `1,21`. Dòng 4:

- A = `=SUM(A2:A3)`
- B = `=SUM(B2:B3)`
- C = `=SUM(C2:C3)`
- E = `=SUM(E2:E3)`
- D trống.

### 8.7 Field loại file

Mở `/admin/excel_exports/new`.

- Mặc định **File hiện tại**. Card cột có header `Tên Đại lý` và câu bill hold.
- Chọn **Kết toán theo phí gốc**. Card cột đổi thành Số tiền giao dịch, Số tiền đã khấu trừ cho đại lý, Số tiền sau khi trừ phí gốc, Tỷ lệ, Lợi nhuận, Số Lô, Ngày giao dịch, Giờ giao dịch, Tên đại lý, Tên HKD. Không còn câu bill hold.
- Chọn lại **File hiện tại**. Card cột trở về danh sách cũ.
- Gửi form với **Kết toán theo phí gốc** và khoảng `2026-10-04`: bản ghi `layout` là `ket_toan_phi_goc`, file không có sheet `Giao dịch` hay `Tổng hợp`, tên khớp `smc-ket-toan-phi-goc-20261004-` cộng sáu chữ số giờ.
- Gửi form không đổi option vẫn ra `legacy`, sheet `Giao dịch` và `Tổng hợp`, tên `smc-20261004.xlsx`.
- Dashboard **Tổng quan** không có nút xuất file này.

## 9. Việc cấu hình để thử bằng giao dịch #6

Giao dịch thẻ thường vào sheet `1,21` khi hộ có quy tắc **Phí gốc `1,21`**, **Phí đại lý `1,40`**, và giao dịch đã duyệt chốt hai số đó.

Giao dịch thẻ MB hoặc Napas của hộ đó vào cùng sheet `1,21` khi có thêm quy tắc loại thẻ, ví dụ MB **Phí gốc `0,88`**, **Phí đại lý `1,20`**. Không cần duyệt lại để đổi snapshot: file đọc quy tắc loại thẻ lúc xuất. Vào `/admin/excel_exports/new`, chọn **Kết toán theo phí gốc**, khoảng ngày có `transaction_at` của giao dịch.
