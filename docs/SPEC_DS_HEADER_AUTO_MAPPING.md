# Spec kỹ thuật: Tự dò header đại lý và tự đổi đại lý khi Google Sheet đổi

| | |
|---|---|
| Trạng thái | Đã triển khai trên nhánh `feature/ds-header-auto-mapping`: bước 1 đến 4 đã commit (`8cd6c9d`), bước 5 (bỏ `Bill vô chủ`) chưa commit (16/10/2026). Xem mục 13. |
| Phạm vi | `Workbook::HelloSmcWriter` (`increment_daily`, bỏ nhánh `Bill vô chủ`), `Transaction::TRANSITIONS`, trang kiểm tra (lý do + link), `Workbook::DsHeaderMatcher` (mới), `Transactions::DealerReassigner` (mới), `AppSetting`, `Workbook::Seed`, nút "Đồng bộ header" trên trang HKD, rake task |
| Áp dụng từ | Tháng 10/2026 trở đi (tab `DS MB T10` và các tab sau) |
| Không đổi | OCR, nhận diện HKD/TID (`TidParser`, `Dealers::Resolver`), sheet `thu chi`, mã chuyển tiền, luồng QR chuyển khoản |

---

## 1. Vấn đề và mục tiêu

Bill tiền vào được cộng dồn vào `DS MB T<tháng>`: mỗi ô là tổng tiền của **một đại lý (TID) trong một ngày** của một HKD. Writer tìm cột bằng cách so tên header trong sheet với `merchant_dealers.ds_header`. Client sửa header trên sheet bất cứ lúc nào (đổi tên, hoặc đổi sang người khác). Khi header đổi mà DB không đổi theo, `increment_daily` không thấy cột (`CellMissing "ds_header"`) và bill rơi vào `Bill vô chủ`.

Mục tiêu: client chỉ cần sửa Google Sheet, app **tự phát hiện** header đổi và **tự đổi đại lý** khi xác định được người mới, ghi audit log, không ghi bill bằng đại lý cũ. Bill nào writer không đặt được vào sheet thì **về hàng kiểm tra** (mục 2.2), không còn ghi vào `Bill vô chủ`.

**Hiện trạng đã đối chiếu (16/10/2026).** Với Google Sheet production "Final SMC", `DS MB T10` và `T12` khớp 23/23 dòng đại lý của `seed.rb` (đối chiếu bằng script theo cùng quy tắc chuẩn hoá của `SheetText#normalize_text`). Trong tab `MB` có 214 dòng do app ghi (12 đến 16/10) và tab `Bill vô chủ` chỉ có 4 dòng do app ghi, không dòng nào của Cherry hay AS CAFE. Nên chưa thấy sự cố mapping; spec này là **phòng ngừa**. Chưa kiểm tra được bảng `merchant_dealers` thật. Lưu ý: tên đại lý thật trên production có thể khác `seed.rb` (ví dụ `MB` ghi `Nghĩa` thay vì `Nghĩa Nghiệp`); việc phân loại ở mục 3 luôn dùng `dealers.name` trong DB, không dùng seed.

## 2. Luồng khi ghi bill

`HelloSmcWriter#write_identified` đang giữ khoá dòng giao dịch và khoá sheet. Giao dịch lúc này đã `approved` và **chưa `booked?`** (chưa có `WorkbookEntry`).

```
increment_daily: tìm ô neo ds_sheet_anchor            → không thấy: CellMissing "ds_anchor" (như cũ)
                 tìm header trùng ds_header trong cửa sổ block (như cũ)
                 → thấy: đi tiếp như cũ (không phân loại, không dò)
                 → không thấy: dò theo TID (mục 3.1)
                                 → không có đúng một cột: CellMissing "ds_header" (như cũ)
                                 → có đúng một cột: phân loại tên (mục 3.2)

phân loại:
  rename   → ghi bill vào cột dò được; sau khi ghi thành công cập nhật ds_header, audit
  switch   (cờ bật)
           1. đổi dealer_id + ds_header của dòng đại lý, audit            (một transaction DB)
           2. sửa giao dịch này sang đại lý mới                           (mục 4)
           3. nhận diện lại để dòng MB dùng tên đại lý mới
           4. ghi bill vào cột dò được
  unmatched, hoặc switch khi cờ tắt, hoặc bước 2 không làm được
           → KHÔNG ghi gì vào sheet; bill về hàng kiểm tra với lý do ds_header_dealer_unmatched (mục 2.2)
```

Điểm giữ nguyên: bill không bao giờ được ghi bằng dữ liệu đại lý cũ khi header đã đổi người, và không bao giờ ghi nhầm cột.

### 2.1 Lớp bảo vệ lúc ghi (một quy tắc cho mọi bill)

Trước khi ghi, bill được chuyển sang đại lý hiện tại của dòng đại lý (`resolution.merchant_dealer`) khi **cả ba** điều sau đúng:

1. `transaction.dealer_id` khác `dealer_id` của dòng đại lý;
2. bill được nhận diện từ chính dòng này lúc đánh giá (`source_data.dealer_resolution.merchant_dealer_id` bằng id dòng);
3. không có **người** nào sửa đại lý của bill trong lúc kiểm tra (`source_data.manual_corrections` không có mục nào vừa có `by` vừa có trường `dealer_id`; lần sửa do hệ thống tự làm có `by` rỗng).

Điều kiện 2 và 3 để không bao giờ ghi đè đại lý mà người kiểm tra đã chọn tay. Quy tắc này xử lý bill đầu tiên phát hiện đổi người, các bill đã duyệt nhưng chưa ghi lúc đó, và bill đánh giá trước khi đại lý đổi. Không sửa được thì bill về hàng kiểm tra với lý do `dealer_reassign_failed`.

### 2.2 Bill không đặt được vào sheet: về hàng kiểm tra (đã chốt 16/10/2026)

Writer không còn ghi vào `Bill vô chủ`. Mọi trường hợp trước đây ghi vào đó giờ **không ghi gì vào sheet, không tạo `WorkbookEntry`**, và bill chuyển `approved → needs_review` (`HelloSmcWriter#send_to_review`):

| Lý do (`review_reasons`) | Khi nào |
|---|---|
| `merchant_missing`, `agent_tid_missing`, `agent_tid_unmapped`, `agent_recipient_mismatch` | Không xác định được HKD, TID hoặc dòng đại lý |
| `ds_cell_missing` | Không thấy tab tháng, ô tên HKD, cột đại lý (kể cả dò theo TID) hoặc ngày trong DS MB |
| `ds_cell_not_numeric` | Ô ngày có chữ hoặc công thức lạ |
| `ds_header_dealer_unmatched` | Header ghi tên người chưa có, khớp nhiều đại lý, đại lý đã tắt, hoặc đổi người khi cờ tắt |
| `dealer_reassign_failed` | Cần chuyển đại lý cho bill nhưng không được (thiếu fee rule, …) |
| `payment_qr_confirmed` | Cần chuyển đại lý nhưng QR chuyển khoản của bill đã xác nhận cho đại lý hiện tại |

- `review_reasons` của bill **thay bằng đúng một lý do** của writer (các lý do lúc đánh giá đã được giải quyết khi duyệt). Review đang mở chuyển `superseded`, tạo review mới `open`. Audit `transaction.sent_to_review` (`metadata.issue`).
- `Transaction::TRANSITIONS` cho phép thêm `approved → needs_review` (chỉ writer dùng). Bill hiện ở hàng "Cần kiểm tra" mặc định và trên dashboard.
- Trang giao dịch và trang kiểm tra hiện lý do tiếng Việt. Với các lý do sửa được ở dòng đại lý (`HelloSmcWriter::MAPPING_ISSUES`: `agent_tid_unmapped`, `agent_recipient_mismatch`, `ds_cell_missing`, `ds_header_dealer_unmatched`, `dealer_reassign_failed`) có link **"Cập nhật đại lý của HKD"** tới trang sửa HKD, chỉ người có quyền quản lý HKD mới thấy.
- **QR chuyển khoản (đã chốt 16/10/2026: giữ giống luồng tạm giữ hiện có).** Code QR không sửa dòng nào; tác động chỉ đến từ các chốt chặn có sẵn:
  - Bill rời `approved` nên yêu cầu QR đã chuẩn bị hết hiệu lực: không gửi Telegram (`DeliverPaymentQrJob` kiểm tra `current?`), xác nhận bị từ chối (`PaymentQrs::Decide`).
  - Duyệt lại xong, yêu cầu cũ **vẫn hết hiệu lực** (thời điểm duyệt đã đổi) và `Approver` không tự làm mới: admin bấm "Làm mới yêu cầu" như khi tạm giữ rồi duyệt lại.
  - Khác trước: bill trước đây vào `Bill vô chủ` vẫn ở `approved` nên luồng QR vẫn chạy; nay phải qua kiểm tra trước khi trả tiền.
- Client sửa cấu hình hoặc sheet rồi duyệt lại: `Approver` xếp job ghi như thường. Nếu header khớp một đại lý có sẵn thì writer tự `switch` (mục 3.2). Chưa sửa thì bill lại về hàng kiểm tra.
- **Không để bill kẹt giữa duyệt và kiểm tra:**
  - **TID không cho ra dòng đại lý** (bill không có TID, TID chưa cấu hình, người nhận mâu thuẫn với TID): bill đã được người duyệt với một đại lý cụ thể, nên `Workbook::Resolver` dùng **dòng đại lý active duy nhất** của cặp (HKD, đại lý của bill). Đại lý có nhiều dòng trong HKD đó (ví dụ Chị Huệ có TID 127, 128, 129 ở MILO) thì vẫn về kiểm tra; màn hình kiểm tra chưa có chỗ chọn TID nên trường hợp này phải sửa tay trên sheet (giới hạn đã biết).
  - **QR đã xác nhận (`payment_qr_confirmed`):** người kiểm tra duyệt lại thì bill **giữ đại lý đang có** (đã được trả tiền) và được ghi vào cột theo TID; muốn chuyển sang đại lý mới thì sửa đại lý trên bill rồi duyệt. Nhận biết bằng `source_data.workbook_review.issue` mà `send_to_review` ghi lại.
  - Cột I của dòng `MB` vẫn ghi tên đại lý của cột (theo TID) như trước, kể cả khi bill giữ đại lý khác.
- Dữ liệu cũ giữ nguyên: các dòng đã có trên tab `Bill vô chủ` và các `WorkbookEntry` nhánh `unidentified` vẫn hiển thị trên trang giao dịch. Tab `Bill vô chủ` không nhận dòng mới từ app.

### 2.3 Retry

Writer chạy trong một transaction DB (`with_lock` của giao dịch). Đổi đại lý, sửa giao dịch và ghi `WorkbookEntry` cùng nằm trong transaction đó, nên nếu ghi sheet lỗi thì **cả đổi đại lý lẫn sửa giao dịch cùng bị hoàn lại**; lần retry làm lại từ đầu và đổi đúng một lần. Trường hợp Google đã áp dụng ghi nhưng báo lỗi (timeout): lần retry thấy marker `TX<id>` ở sheet và chỉ ghi nhận (`reconcile!`), không đổi đại lý lúc đó; header đổi sẽ được xử lý ở bill kế tiếp hoặc khi bấm "Đồng bộ header".

## 3. Dò cột và phân loại header

### 3.1 Dò cột theo TID (`Workbook::DsHeaderMatcher`)

1. **Block của HKD:** các cột từ ô neo sang phải trên hàng header, dừng ở ô header trống đầu tiên hoặc `DS_LAST_COL`. Không dùng cửa sổ cứng 7 cột của đường so tên (có thể chạm sang block bên cạnh).
2. **Đọc TID** của mỗi header bằng `Workbook::TidParser.call` (`Nghĩa (tid1)` → `tid1`, `Chị Huệ (TID 127)` → `tid127`).
3. **Loại cột đã thuộc đại lý khác:** bỏ qua header trùng `ds_header` của một `merchant_dealers` active khác cùng HKD.
4. **Chỉ nhận khi còn đúng một cột** có TID bằng `link.tid_key`. Không có hoặc nhiều hơn một thì không dò được (giữ lỗi cũ `ds_header`).
5. Ô neo (tên HKD) vẫn phải khớp `ds_sheet_anchor`; không dò theo TID cho ô neo.

### 3.2 Phân loại tên người

Tên người = text header sau khi bỏ `(tidN)` / `(TID N)` và hậu tố kênh `MB`, `SP`, `QR`, gom khoảng trắng. So bằng `VietnameseText.normalize` (bỏ dấu, hoa thường). Thứ tự kiểm tra, dừng ở điều kiện đầu tiên đúng:

| Thứ tự | Loại | Điều kiện | Hành động |
|---|---|---|---|
| 1 | `same` | Trùng tên đại lý hiện tại của dòng | Chỉ cập nhật `ds_header` nếu text header khác (ví dụ khác khoảng trắng) |
| 2 | `switch` | **Trùng nguyên văn** (sau chuẩn hoá) tên của **đúng một** `Dealer` khác đang hoạt động | Đổi đại lý (mục 2, bước 1) |
| 3 | `rename` | Dãy từ của một bên nằm trọn trong dãy từ của bên kia so với đại lý hiện tại (`Nghĩa` và `Nghĩa Nghiệp`) | Giữ đại lý, cập nhật `ds_header` |
| 4 | `unmatched` | Còn lại: tên mới chưa có trong hệ thống, khớp từ hai đại lý trở lên, chỉ khớp một đại lý đã tắt, tên rỗng hoặc ngắn hơn 2 ký tự | Không ghi, về hàng kiểm tra với `ds_header_dealer_unmatched` |

`switch` đứng trước `rename` để tên trùng một đại lý khác được đổi đại lý, không bị coi là đổi tên (ví dụ dòng đang là `Hải`, header đổi thành `Anh Hải` mà `Anh Hải` là một đại lý có sẵn). Không bao giờ tự tạo `Dealer` mới; tên chưa có thì admin tạo đại lý hoặc sửa dòng đại lý như hiện nay, rồi duyệt lại bill trong hàng kiểm tra.

### 3.3 Lưu thay đổi

- `rename` và `same`: cập nhật `merchant_dealers.ds_header` = text gốc của ô header (đã `strip`) **sau khi** ghi sheet thành công. Lỗi lưu DB chỉ ghi log, bill đã ghi vẫn được nhận. Audit `merchant_dealer.ds_header_synced` (`from`, `to`, `sheet`, `transaction_id`).
- `switch`: trong một transaction DB đặt `dealer_id` mới và `ds_header` = text header vừa đọc. Callback `forget_names_of_previous_agent` của `MerchantDealer` xoá `rd_agent_label` và `tid_label` cũ để mặc định theo đại lý mới; `rd_agent_label` mặc định là tên đại lý (nếu không khớp block trong tab `thu chi`, lệnh ghi thu chi báo `rd_agent_missing` như hiện nay và admin chỉnh nhãn). `transfer_code` giữ nguyên (gắn với HKD + TID, không gắn người). Audit `merchant_dealer.agent_switched` (`from_dealer`, `to_dealer`, `header_trước`, `header_sau`, `sheet`, `source`: `writer` hoặc `sync`, `transaction_id` nếu có). `has_paper_trail` giữ bản cũ nên đổi ngược được trên trang HKD.

## 4. Sửa giao dịch đã duyệt nhưng chưa ghi sheet (`Transactions::DealerReassigner`)

`Transactions::Corrector` chỉ sửa trạng thái `needs_review`, `hold`, `failed` (`EDITABLE_STATUSES`) nên từ chối giao dịch `approved`. Service mới `DealerReassigner.call(transaction:, dealer:, source:)`:

1. Khoá dòng giao dịch; từ chối nếu `booked?`.
2. `approved` → `hold` (đường chuyển có sẵn trong `Transaction::TRANSITIONS`) → gọi `Corrector` với `dealer_id` mới (tính lại phí theo `fee_rule` của đại lý mới, ghi audit before/after) → `hold` → `approved` bằng `transition_to!("approved", approved_by: <giữ giá trị cũ>, approved_at: <giữ giá trị cũ>)`. **Không** gọi `Transactions::Approver`, vì `Approver` xếp lại job ghi sheet mà writer đang chạy.
3. Yêu cầu QR đã tạo lúc duyệt cho người cũ tự mất hiệu lực (ảnh chụp người nhận không còn khớp, `DealerPaymentQr#current?` là `false`). Nếu đại lý mới `auto_payment_qr?` thì gọi `PaymentQrs::Prepare` như `Approver` (`approver.rb`). Yêu cầu đã xác nhận của giao dịch khác giữ nguyên.
4. Audit `transaction.dealer_reassigned` (đại lý cũ → mới, `source`).

Phí của đại lý mới lấy từ `fee_rule` mặc định đã có cho mọi đại lý và mọi loại thẻ. Giao dịch đã `booked?` không bao giờ bị sửa.

## 5. Cờ bật tắt `ds_header_auto_switch`

- `AppSetting::DEFINITIONS`: `define("ds_header_auto_switch", :boolean, "true", "operations")`. **Mặc định bật.** Hiện trong trang Cài đặt cùng nhóm công tắc "operations" (`SettingsForm`), có nhãn và mô tả ở `config/locales/vi.yml`. Đọc bằng `AppSetting.get("ds_header_auto_switch")` (đệm 30 giây). Đổi cờ có paper trail của `AppSetting`.
- Cờ tắt: `switch` xử lý như `unmatched` (không ghi, về hàng kiểm tra với `ds_header_dealer_unmatched`). `rename` và dò theo TID không phụ thuộc cờ. Lớp bảo vệ 2.1 vẫn chạy khi admin đã đổi đại lý tay, vì đó là giữ dữ liệu nhất quán.

## 6. Nút "Đồng bộ header" và rake task (bắt buộc)

Chạy cùng `DsHeaderMatcher.locate` và quy tắc phân loại cho mọi dòng đại lý active (`Workbook::DsHeaderSync`) trên `DS MB T<tháng hiện tại>`, không cần có bill:

- Nút trên `merchants/show` ("Đồng bộ header", chỉ người có quyền quản lý HKD), action `POST admin/merchants/:id/sync_headers` xử lý riêng HKD đó. Kết quả hiện bằng flash: số dòng `khớp`, `đổi tên`, `đổi đại lý`, `chưa xác định`, `không thấy cột`; lỗi (chưa cấu hình sheet, chưa có tab tháng, sheet bận, lỗi Google) hiện bằng một thông báo lỗi.
- Rake task `hellosmc:ds_headers:check` (chỉ in báo cáo, không ghi) và `hellosmc:ds_headers:sync` (áp dụng) xử lý tất cả HKD.
- Mỗi lần chạy tốn một lượt đọc một tab và giữ `SheetLock` như writer. `unmatched` và `missing` chỉ báo cáo. Đổi đại lý bằng nút hoặc rake ghi audit `merchant_dealer.agent_switched` với `source = "sync"` hoặc `"rake"`; các bill đang chờ ghi được lớp bảo vệ 2.1 sửa khi tới lượt ghi.
- Job định kỳ (cron) **chưa làm** ở bản này, cân nhắc sau.

## 7. `Workbook::Seed`

`Seed.seed_merchant_dealers` tìm dòng theo (đại lý, TID) rồi ghi đè `ds_header`, `rd_agent_label` mỗi lần chạy. Sau khi tự đổi đại lý, chạy lại seed không thấy cặp (đại lý cũ, TID), tạo thêm dòng active cùng TID và vi phạm ràng buộc duy nhất `(merchant_id, tid_key)` khi dòng active, nên seed báo lỗi. Sửa: seed **bỏ qua** cặp (HKD, TID) mà dòng active hiện thuộc đại lý khác tên; các dòng còn lại giữ hành vi cũ (điền và sửa nhãn lệch).

## 8. Trường hợp biên

| Trường hợp | Kết quả |
|---|---|
| Header khớp `ds_header` | Như cũ, không dò, không phân loại |
| Hai header trong block cùng TID (sheet nhập sai) | Không dò, về hàng kiểm tra với `ds_cell_missing` |
| Header không có TID | Không dò, về hàng kiểm tra với `ds_cell_missing` |
| Cột có TID đúng nhưng là `ds_header` của đại lý khác cùng HKD | Bỏ qua cột đó |
| Block HKD kề nhau, cột trống ngăn cách | Dò dừng ở cột trống |
| Tên đại lý trùng ở nhiều HKD (Sơn, Cường Duyên, Trân, Anh Hải) | Cùng một `Dealer`; không mơ hồ nếu bảng `dealers` không có hai bản ghi cùng tên chuẩn hoá. Nếu có thì `unmatched` |
| Tên chứa nhau (`Hải` và `Anh Hải`, `Thọ` và `Anh Thọ`) | `switch` ưu tiên khi trùng nguyên văn một đại lý khác; không thì `rename` |
| Bill đã duyệt nhưng chưa ghi lúc header đổi | Lớp bảo vệ 2.1 sửa sang đại lý mới trước khi ghi |
| Giao dịch đã `booked?` | Không bao giờ bị sửa |
| Lưu DB lỗi sau khi ghi sheet (rename) | Chỉ log; lần ghi sau dò lại |
| Cờ tắt | `switch` thành `unmatched`; `rename` vẫn chạy |
| Admin đổi đại lý trên trang HKD nhưng sheet vẫn ghi tên người cũ | Sheet là nguồn đúng: bill kế tiếp (hoặc "Đồng bộ header") đổi dòng về người trên sheet, có audit `merchant_dealer.agent_switched`. Muốn đổi người thì sửa trên sheet |
| QR chuyển khoản của bill đã được xác nhận | Không tự chuyển đại lý (có thể đã trả tiền cho người cũ); bill về hàng kiểm tra với `dealer_reassign_failed` để người quản lý xử lý |
| Không tìm được ô ngày hoặc ô ngày không cộng được | Không đổi đại lý; bill về hàng kiểm tra (`ds_cell_missing` / `ds_cell_not_numeric`) |
| Tab tháng mới | `monthly_sheet` nhân từ tab có số tháng lớn nhất, nên header mới đi theo |

## 9. Kiểm thử

| Spec | Nội dung |
|---|---|
| `spec/services/workbook/ds_header_matcher_spec.rb` | Dò theo TID (một cột, hai cột cùng TID, cột của đại lý khác, dừng ở cột trống, quá `last_col`), phân loại `same` / `rename` / `switch` (ưu tiên hơn `rename`) / `unmatched` (tên mới, đại lý đã tắt, nhiều đại lý, tên rỗng), `.locate` |
| `spec/services/workbook/hello_smc_writer_spec.rb` (khối "DS MB header changes") | `rename` ghi đúng cột và lưu header, header khớp thì không audit, `switch` đổi đại lý và giao dịch và dòng `MB`, giữ `approved_by`/`approved_at`, tên chưa có thì về hàng kiểm tra, cờ tắt, rename khi cờ tắt, không chuyển được đại lý thì `dealer_reassign_failed`, bill đánh giá trước khi đổi đại lý được chuyển, đại lý chọn tay không bị ghi đè, ghi sheet lỗi thì hoàn lại cả đổi đại lý và retry đổi đúng một lần |
| `spec/services/workbook/hello_smc_writer_spec.rb` (khối "bill the writer cannot place") | Không ghi gì, bill về `needs_review` với đúng lý do và review mới, audit `transaction.sent_to_review`, lý do cũ được thay, sửa cấu hình và duyệt lại thì ghi đúng (kèm `switch`) |
| `spec/services/workbook/resolver_spec.rb` (khối "a bill whose TID gives no agent row") | Dùng dòng đại lý duy nhất của đại lý trên bill; nhiều dòng thì vẫn chưa xác định |
| `spec/services/workbook/hello_smc_writer_spec.rb` (thêm) | Bill không có TID được ghi vào cột duy nhất của đại lý; QR đã xác nhận: về kiểm tra một lần, duyệt lại thì ghi và giữ đại lý |
| `spec/requests/admin/workbook_review_reasons_spec.rb` | Lý do tiếng Việt và link "Cập nhật đại lý của HKD" (ẩn với người chỉ xem) |
| `spec/models/transaction_spec.rb` | Cho phép `approved → needs_review` |
| `spec/services/transactions/dealer_reassigner_spec.rb` | Chuyển đại lý, tính lại phí, giữ duyệt, audit, không xếp lại job ghi, bill đã vào sổ hoặc chưa duyệt bị từ chối, thiếu fee rule thì hoàn lại, yêu cầu QR bị chặn hoặc tạo lại theo tài khoản đại lý mới |
| `spec/services/workbook/ds_header_sync_spec.rb` | Báo cáo `ok` / `renamed` / `switched` / `unmatched` / `missing`, chế độ chỉ kiểm tra không ghi, giới hạn theo HKD, thiếu tab tháng |
| `spec/requests/admin/merchant_header_sync_spec.rb` | Nút "Đồng bộ header", thông báo kết quả và lỗi, người chỉ xem không có nút và bị chặn |
| `spec/tasks/ds_headers_spec.rb` | `check` chỉ in báo cáo, `sync` áp dụng |
| `spec/services/workbook/seed_spec.rb` | Seed chạy lại không lỗi và không đổi dòng đã chuyển đại lý |
| `spec/models/app_setting_spec.rb`, `settings_form_spec.rb`, `spec/requests/settings_spec.rb` | Cờ `ds_header_auto_switch` mặc định bật, hiện trong Cài đặt |

## 10. Thứ tự làm

1. `DsHeaderMatcher` (dò theo TID, phân loại, `.locate`) kèm spec. **Xong.**
2. Nối vào `increment_daily` và `write_identified`: `rename`, `unmatched`; sửa `Workbook::Seed`. **Xong.**
3. `DealerReassigner`, lớp bảo vệ 2.1, `switch`, cờ `ds_header_auto_switch`, `DsHeaderChange`. **Xong.**
4. Nút "Đồng bộ header" (`DsHeaderSync`) và rake task. **Xong.**
5. Bỏ `Bill vô chủ`: mọi bill writer không đặt được về hàng kiểm tra kèm lý do và link tới cấu hình đại lý (mục 2.2). **Xong** (16/10/2026).
6. Không để bill kẹt giữa duyệt và kiểm tra: dùng dòng đại lý duy nhất của đại lý trên bill khi TID không cho ra dòng; giữ đại lý khi QR đã xác nhận và người duyệt lại (mục 2.2). **Xong** (16/10/2026).

## 11. Đã chốt khi làm và việc cần kiểm chứng

Đã chốt (16/10/2026):
- Sau khi sửa đại lý, giao dịch **tự động về `approved`** (không chờ người duyệt lại) bằng chuyển trạng thái trực tiếp, giữ `approved_by` và `approved_at` cũ (mục 4).
- ~~Issue mới của `Bill vô chủ` hiển thị như issue cũ~~ Thay bằng: bỏ `Bill vô chủ`, bill về hàng kiểm tra với lý do hiển thị rõ (mục 2.2).

Cần kiểm chứng khi làm:
- `hold` → `approved` bằng `transition_to!` có cần ghi thêm `reviews` như luồng duyệt thường không. Nếu cần thì dùng `Transactions::StatusUpdater` cho phần chuyển `hold`.
- Chạy spec: `export PATH="$HOME/.rbenv/versions/3.4.10/bin:$PATH" DB_HOST=localhost DB_USERNAME=postgres DB_PASSWORD=postgres RAILS_ENV=test` rồi `bin/rails db:prepare` và `bundle exec rspec`. `db:prepare` làm đổi định dạng `db/schema.rb` (khác phiên bản Postgres), cần `git checkout -- db/schema.rb` sau khi chạy.

## 12. Ngoài phạm vi (làm sau nếu cần)

Bảng đề xuất và chip chờ xác nhận trong cấu hình HKD, lý do kiểm tra `dealer_mapping_pending` kèm link tới cấu hình, tự tạo `Dealer` mới, tự áp dụng đại lý mới cho giao dịch đang chờ sau khi admin xác nhận, job định kỳ, tự dò `rd_agent_label` trên tab `thu chi`, xử lý QR riêng khi đổi đại lý. Bản đầy đủ trước khi gọn lại được giữ ở thư mục tạm của phiên làm việc, có thể lấy lại khi cần.

## 13. Trạng thái triển khai (16/10/2026)

Bước 1 đến 4 ở mục 10 đã commit (`8cd6c9d`) trên nhánh `feature/ds-header-auto-mapping`. Bước 5 (bỏ `Bill vô chủ`) đã làm, **chưa commit**. Không thêm gem nào.

Khác với bản đầu của spec, khi làm có ba điều chỉnh:
- **Lớp bảo vệ 2.1:** điều kiện chặt hơn (mục 2.1) để không ghi đè đại lý người kiểm tra chọn tay. Bản đầu chỉ so `dealer_id` và sẽ làm vậy.
- **Retry (mục 2.3):** đổi đại lý nằm trong transaction của lần ghi nên bị hoàn lại cùng lần ghi lỗi, không "đã commit trước" như bản đầu.
- **Seed (mục 7):** bỏ qua cặp (HKD, TID) đã chuyển đại lý, vẫn sửa nhãn lệch của các dòng còn lại.

Kết quả chạy test (trong container `hellosmc-web-1`, `RAILS_ENV=test`):
- Toàn bộ suite (sau review lần 3): **1263 ví dụ, 2 lỗi**. Các spec của tính năng chạy 3 lần với thứ tự ngẫu nhiên (seed 1, 4242, 98765): 188 ví dụ, 0 lỗi mỗi lần. Có thêm một ca chạy cả luồng: bill đầu đổi đại lý, bill đánh giá trước đó đi theo, bill sau khớp luôn. Hai lỗi nằm ở `spec/requests/remitter_transfers_spec.rb:16` và `:30` (cột ngày giờ của trang chuyển tiền). Chạy trên cây sạch ở commit `233bdcd` (trước mọi thay đổi này) cũng lỗi y như vậy, nên không do thay đổi này.
- `rubocop` trên các file đã sửa hoặc thêm: không có lỗi (riêng `workbook/seed.rb` có 46 lỗi định dạng sẵn có, không do thay đổi này).
- Đã thử phá có chủ đích (đảo thứ tự `switch` và `rename`, bỏ rollback của `DealerReassigner`): spec tương ứng báo lỗi.

Review lần 2 (16/10/2026), đã sửa và có test cho từng lỗi (thử bỏ từng chỗ sửa thì test tương ứng báo lỗi):
- Bill có QR chuyển khoản **đã xác nhận** bị tự chuyển đại lý, làm mới yêu cầu QR cũ và có thể trả tiền hai lần. Nay `DealerReassigner` từ chối (`payment_qr_confirmed`).
- Lần chuyển đại lý tự động ghi vào `manual_corrections` (`by` rỗng) bị lớp bảo vệ 2.1 hiểu nhầm là người chọn tay. Nay chỉ tính mục có `by`.
- Đổi đại lý xảy ra trước khi kiểm tra ô ngày, nên bill không ghi được DS MB vẫn làm đổi đại lý. Nay chỉ đổi sau khi chắc chắn ghi được ô.
- Lỗi của nút "Đồng bộ header" không được ghi log. Nay ghi `workbook.ds_header_sync_failed`.

Hiệu năng: khi header khớp (trường hợp thường gặp), lần ghi bill không có thêm truy vấn DB hay lượt gọi Google nào so với trước. Chỉ khi header lệch mới có 2 truy vấn nhỏ (dòng đại lý cùng HKD, danh sách đại lý).

Chưa làm được:
- Chạy thử với Google Sheet thật (mọi kiểm thử dùng `Workbook::MemorySheet`).
- Tài liệu khác còn mô tả `Bill vô chủ` theo cách cũ (`docs/SPEC_HELLO_SMC_WORKBOOK.md`, `docs/PROJECT_CONTEXT.md`); chưa sửa vì ngoài phạm vi spec này.

Bước 5 (bỏ `Bill vô chủ`, 16/10/2026):
- Làm theo mục 2.2. Code ghi `Bill vô chủ` (`write_unidentified`, `append_unidentified`, các hằng `UNIDENTIFIED_*`) đã xoá.
- Khi chạy test phát hiện thêm một lỗi của `DealerReassigner`: chuyển bill thất bại thì DB được hoàn lại nhưng object giao dịch trong bộ nhớ vẫn mang trạng thái `hold` và `lock_version` cũ, lần cập nhật sau báo `StaleObjectError` (trước đây lỗi này làm cột "Trạng thái" của dòng `Bill vô chủ` ghi sai thành "Cần kiểm tra"). Nay nạp lại giao dịch sau khi hoàn lại; có test, thử bỏ chỗ sửa thì 2 test báo lỗi.
- Bước 6 (không để bill kẹt): thử bỏ từng chỗ sửa thì test tương ứng báo lỗi. Toàn bộ suite sau bước 6: **1271 ví dụ, 2 lỗi** (vẫn 2 lỗi sẵn có).
- Kết quả trước bước 6: toàn bộ suite **1267 ví dụ, 2 lỗi** (vẫn là 2 lỗi sẵn có ở `spec/requests/remitter_transfers_spec.rb:16` và `:30`); `rubocop` sạch trên các file đã sửa.
