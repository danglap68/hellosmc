# Spec kỹ thuật: Theo dõi header đại lý trong `DS MB T<tháng>` và đưa bill không ghi được về hàng kiểm tra

| | |
|---|---|
| Trạng thái | Đã triển khai trên nhánh `feature/ds-header-auto-mapping`: `8cd6c9d`, `d992360`, `46c285f` (bill có người duyệt giữ nguyên đại lý, mục 3.4) (17/10/2026). |
| Áp dụng từ | Tháng 10/2026 trở đi (tab `DS MB T10` và các tab sau) |
| Không đổi | OCR, nhận diện HKD (`Merchants::Resolver`), `Dealers::Resolver`, `TidParser`, tab `thu chi`, mã chuyển tiền, code QR chuyển khoản |

---

## 1. Mục đích

Bill tiền vào được cộng dồn vào `DS MB T<tháng>`: mỗi ô là tổng tiền của **một đại lý (TID) trong một ngày** của một HKD. Writer tìm cột bằng cách so chữ ở ô tiêu đề cột với `merchant_dealers.ds_header`. Client sửa tiêu đề trên Google Sheet bất cứ lúc nào.

- Đổi cách ghi tên của **cùng người** (ví dụ `Nghĩa Nghiệp (tid1)` → `Nghĩa (tid1)`): bill vẫn ghi đúng cột, app tự lưu tên cột mới.
- Đổi sang **người khác**: không ghi tiền theo phỏng đoán. Nếu tên mới trùng đúng một đại lý đã có và cờ `ds_header_auto_switch` bật thì dòng đại lý tự đổi theo; ngoài ra bill về hàng kiểm tra để admin xử lý.
- Bill writer không đặt được vào sheet thì **về hàng kiểm tra** với lý do, không ghi vào tab `Bill vô chủ` nữa.

Đổi người theo cách đơn giản nhất: admin chọn lại đại lý ở ô "Đại lý" trong form HKD (có thể tắt cờ để chỉ đổi tay).

## 2. Dò cột và phân loại tiêu đề (`Workbook::DsHeaderMatcher`)

### 2.1 Tìm cột (`DsHeaderMatcher.locate`)

1. Ô neo: ô đầu tiên (theo hàng rồi cột) có chữ khớp `ds_sheet_anchor`. Không có thì `CellMissing "ds_anchor"`.
2. Tìm theo tên: trong 7 cột từ ô neo, cột có chữ khớp `ds_header` (so bằng `SheetText#same_text?`: bỏ dấu, hoa thường, khoảng trắng, `tid 1` = `tid1`). Thấy thì dùng cột đó, không có thay đổi gì.
3. Không thấy thì tìm theo TID trong **block của HKD**: các cột từ ô neo sang phải, dừng ở ô tiêu đề trống đầu tiên hoặc cột `X`. Bỏ qua tiêu đề trùng `ds_header` của dòng đại lý active khác cùng HKD. TID đọc bằng `TidParser`. Chỉ nhận khi còn **đúng một cột** có TID của dòng; không thì `CellMissing "ds_header"`.

### 2.2 Phân loại khi tìm theo TID

Tên người = chữ tiêu đề bỏ `tidN` / `terminal N` và hậu tố kênh `MB`, `SP`, `QR`, so theo từ sau `VietnameseText.normalize`. Thứ tự, dừng ở điều kiện đầu tiên đúng:

| Loại | Điều kiện | Xử lý |
|---|---|---|
| `unmatched` | Tên ngắn hơn 2 ký tự | Bill về kiểm tra (`ds_header_dealer_unmatched`) |
| `same` | Trùng tên đại lý hiện tại | Ghi bill; sau khi ghi lưu tiêu đề mới vào `ds_header` |
| `switch` / `unmatched` | Trùng **đúng** tên đại lý khác: đúng một đại lý đang hoạt động → `switch`; nhiều đại lý hoặc một đại lý đã tắt → `unmatched` | Mục 3.3 |
| `rename` | Các từ của tên này nằm liền nhau trọn trong tên kia (`Nghĩa` / `Nghĩa Nghiệp`, `Chị Hà` / `Hà`) | Như `same` |
| `unmatched` | Còn lại (tên chưa có trong hệ thống) | Bill về kiểm tra (`ds_header_dealer_unmatched`) |

Không bao giờ tự tạo `Dealer`. Quy tắc "tên chứa nhau là cùng người" giữ nguyên: thực tế tiêu đề thường ghi tên ngắn, trường hợp "Hà" → "Hà Thu Trang" (người mới) hiếm; khi xảy ra admin đổi đại lý ở form HKD.

## 3. Luồng ghi bill (`Workbook::HelloSmcWriter`)

Writer chạy trong `transaction.with_lock` và `SheetLock`, chỉ với bill `approved` chưa có `WorkbookEntry`.

### 3.1 Nhận diện dòng đại lý (`Workbook::Resolver`)

- TID lấy từ tên HKD do OCR đọc; dòng đại lý theo `Dealers::Resolver` (TID, tên người nhận chuyển khoản).
- Không ra dòng nào (bill không có TID, TID chưa có dòng trong HKD, người nhận mâu thuẫn với TID): dùng **dòng đại lý active duy nhất** của cặp (HKD, đại lý trên bill), vì bill đã được người duyệt với đại lý đó. Đại lý có 0 hoặc từ 2 dòng trong HKD thì không nhận diện được.
- Không nhận diện được → bill về kiểm tra với `merchant_missing`, `agent_tid_missing`, `agent_tid_unmapped` hoặc `agent_recipient_mismatch`.

### 3.2 Các bước

1. Tab `MB` đã có marker `TX<id>` → chỉ ghi nhận (`reconcile!`), không ghi lại.
2. Lớp bảo vệ (mục 3.4): bill mang đại lý cũ của dòng thì chuyển sang đại lý hiện tại của dòng.
3. Tìm cột (mục 2.1), ô ngày, kiểm tra ô cộng được (công thức cộng dồn). Lỗi → `ds_cell_missing` hoặc `ds_cell_not_numeric`.
4. Chỉ khi ô đã chắc chắn ghi được mới xử lý thay đổi tiêu đề `switch` / `unmatched` (mục 3.3).
5. Ghi DS MB và MB trong một `batchUpdate`, tạo `WorkbookEntry`.
6. Loại `same` / `rename`: lưu tiêu đề mới (`DsHeaderChange.rename!`, audit `merchant_dealer.ds_header_synced`), trong savepoint; lỗi chỉ ghi log `workbook.ds_header_not_saved`.

Mọi thay đổi DB nằm chung transaction với lần ghi: ghi sheet lỗi thì đổi đại lý và chuyển bill cùng bị hoàn lại, lần chạy lại làm lại từ đầu. Google đã ghi nhưng sau đó DB lỗi: lần chạy lại thấy marker và chỉ ghi nhận, việc đổi đại lý xảy ra ở bill kế tiếp hoặc khi bấm "Đồng bộ header" (hiếm, chấp nhận).

### 3.3 Tiêu đề ghi tên đại lý khác

- `switch` khi cờ `ds_header_auto_switch` **bật**: đổi dòng đại lý sang đại lý đó (`DsHeaderChange.switch!`: `dealer_id`, `ds_header`; nhãn thu chi về tên đại lý; giữ `transfer_code`; audit `merchant_dealer.agent_switched`). Không đổi được (ví dụ đại lý đó đã có dòng cùng TID ở HKD) → `ds_header_dealer_unmatched`. Sau đó chuyển bill theo mục 3.4.
- `switch` khi cờ **tắt**, hoặc `unmatched`: không đổi gì, bill về kiểm tra với `ds_header_dealer_unmatched`.
- Sau khi đổi dòng, nhãn thu chi là tên đại lý (ví dụ "Anh Hùng"); nếu tab thu chi ghi khác ("Hùng") admin phải sửa ô "Nhãn đại lý ở tab thu chi", không thì lệnh đi tiền của mã chuyển tiền đó báo `rd_agent_missing`.

### 3.4 Chuyển bill sang đại lý hiện tại của dòng

Bill được chuyển (`Transactions::DealerReassigner`) khi **tất cả** đúng:

1. Bill do **hệ thống tự duyệt** (`approved_by` rỗng). Bill có người duyệt **giữ nguyên đại lý** và vẫn được ghi vào cột theo TID; muốn sang người mới thì người kiểm tra chọn đại lý mới trên bill rồi duyệt.
2. Không phải bill đã từng về kiểm tra vì `payment_qr_confirmed` (nhận biết qua `source_data.workbook_review.issue`).
3. Với lớp bảo vệ ở bước 2 của mục 3.2: bill mang đại lý khác đại lý của dòng, được nhận diện từ chính dòng này lúc đánh giá (`source_data.dealer_resolution.merchant_dealer_id`), và không có người sửa tay đại lý (`manual_corrections` có `by` và `dealer_id`).

`DealerReassigner` (trong savepoint, mọi lỗi để giao dịch như cũ và nạp lại object):
- Từ chối nếu bill đã vào sổ, không còn `approved`, hoặc QR chuyển khoản **đã xác nhận** (`payment_qr_confirmed`, vì có thể đã trả tiền cho người cũ).
- `approved` → `hold` → `Transactions::Corrector` đổi `dealer_id` (tính lại phí theo fee rule của đại lý mới) → `approved`, giữ `approved_by`, `approved_at`; không gọi `Transactions::Approver`.
- Yêu cầu QR: có sẵn thì làm mới (`PaymentQrs::Prepare` với `refresh: true`), chưa có thì tạo nếu đại lý mới `auto_payment_qr?`.
- Audit `transaction.dealer_reassigned`.
- Thất bại → bill về kiểm tra với `payment_qr_confirmed` hoặc `dealer_reassign_failed`.

## 4. Bill không ghi được: về hàng kiểm tra

Writer không còn ghi vào tab `Bill vô chủ`. Mọi trường hợp không đặt được bill: **không ghi gì vào sheet, không tạo `WorkbookEntry`**, `HelloSmcWriter#send_to_review`:

- `source_data.review_reasons` thay bằng đúng một lý do; lưu `source_data.workbook_review = { issue, at }`.
- `approved` → `needs_review` (thêm vào `Transaction::TRANSITIONS`, chỉ writer dùng). Bill hiện ở hàng "Cần kiểm tra" và trên dashboard.
- Review đang mở chuyển `superseded`, tạo review `open` mới; audit `transaction.sent_to_review` (`metadata.issue`).

| Lý do | Khi nào |
|---|---|
| `merchant_missing`, `agent_tid_missing`, `agent_tid_unmapped`, `agent_recipient_mismatch` | Không nhận diện được dòng đại lý (mục 3.1) |
| `ds_cell_missing` | Không có tab tháng, ô tên HKD, cột đại lý hoặc ngày trong DS MB |
| `ds_cell_not_numeric` | Ô ngày có chữ hoặc công thức lạ |
| `ds_header_dealer_unmatched` | Tiêu đề ghi tên người chưa có, nhiều người, đại lý đã tắt, hoặc đổi người khi cờ tắt |
| `dealer_reassign_failed` | Không chuyển được bill sang đại lý mới (ví dụ thiếu fee rule) |
| `payment_qr_confirmed` | Cần chuyển bill nhưng QR đã xác nhận cho đại lý hiện tại |

- Trang giao dịch và trang kiểm tra hiện lý do tiếng Việt (`review_reasons.*` trong `config/locales/vi.yml`). Các lý do trong `HelloSmcWriter::MAPPING_ISSUES` (`agent_tid_missing`, `agent_tid_unmapped`, `agent_recipient_mismatch`, `ds_cell_missing`, `ds_header_dealer_unmatched`, `dealer_reassign_failed`) có link "Cập nhật đại lý của HKD" tới trang sửa HKD, chỉ người có quyền quản lý HKD mới thấy.
- Sửa xong rồi duyệt lại: `Approver` xếp job ghi như thường.
- **QR chuyển khoản** (giống luồng tạm giữ có sẵn, code QR không sửa): rời `approved` làm yêu cầu QR hết hiệu lực (không gửi Telegram, không xác nhận được); duyệt lại xong yêu cầu cũ vẫn hết hiệu lực, admin bấm "Làm mới yêu cầu".
- Dữ liệu cũ giữ nguyên: các dòng đã có trên tab `Bill vô chủ`, các `WorkbookEntry` nhánh `unidentified` và dòng "Hàng Bill vô chủ" trên trang giao dịch.

## 5. Cờ `ds_header_auto_switch`

- `AppSetting::DEFINITIONS`, kiểu boolean, **mặc định bật**, nhóm "Vận hành" trong Cài đặt; đọc qua `AppConfig.ds_header_auto_switch?` (đệm 30 giây).
- Chỉ điều khiển việc đổi dòng đại lý theo tiêu đề (`switch`). Dò cột theo TID, lưu tên cột (`same` / `rename`) và đưa bill về kiểm tra không phụ thuộc cờ.
- Giá trị lưu trong DB của từng môi trường, không đi theo git. Muốn đổi người chỉ bằng tay ở form HKD thì tắt cờ sau khi deploy.

## 6. Nút "Đồng bộ header" và rake task (`Workbook::DsHeaderSync`)

- Đọc tab `DS MB T<tháng hiện tại>` (thiếu tab → lỗi `SheetMissing`), giữ `SheetLock`, chạy cùng `DsHeaderMatcher.locate` cho từng dòng đại lý active, không cần bill. Kết quả: `ok`, `renamed`, `switched`, `unmatched`, `missing`.
- Áp dụng: `same` / `rename` → `rename!`; `switch` → `switch!` khi cờ bật (cờ tắt → `unmatched`). Không chuyển bill nào; bill hệ thống tự duyệt đang chờ ghi được chuyển khi writer tới lượt (mục 3.4).
- Nút trên trang chi tiết HKD (`POST admin/merchants/:id/sync_headers`, cần quyền quản lý HKD), chỉ xử lý HKD đó; flash số dòng theo từng kết quả, lỗi thì báo "Không đồng bộ được header: …" và ghi log `workbook.ds_header_sync_failed`.
- `bin/rails hellosmc:ds_headers:check` (chỉ báo cáo) và `hellosmc:ds_headers:sync` (áp dụng), xử lý tất cả HKD.

## 7. `Workbook::Seed`

Bỏ qua cặp (HKD, TID) mà dòng active đang thuộc đại lý khác tên trong seed (dòng đã đổi người), để chạy lại seed không tạo dòng trùng TID. Các dòng khác giữ hành vi cũ (ghi đè `ds_header`, nhãn thu chi theo seed).

## 8. Giới hạn đã biết

- Câu mô tả cờ trong Cài đặt (`config/locales/vi.yml`, `settings.hints.ds_header_auto_switch`) còn ghi "bill đó được ghi vào Bill vô chủ"; thực tế bill về hàng kiểm tra.
- Đổi dòng đại lý theo tiêu đề không kiểm tra lại nhãn thu chi (mục 3.3).
- Tiêu đề dạng `Huệ (2)`, `Huệ-2` (không có chữ `tid`): dò được cột nhưng số bị coi là một phần tên. Tiêu đề trên Final SMC hiện đều ghi `(tidN)` / `(TID N)`.
- `classify` nạp toàn bộ bảng đại lý; chỉ chạy khi tiêu đề lệch.
- Chưa chạy với Google Sheet thật; kiểm thử dùng `Workbook::MemorySheet`.

## 9. Kiểm thử

| Spec | Nội dung |
|---|---|
| `spec/services/workbook/ds_header_matcher_spec.rb` | Tìm cột theo TID, các loại `same` / `switch` / `rename` / `unmatched`, `.locate` |
| `spec/services/workbook/hello_smc_writer_spec.rb` | Đổi tên, đổi đại lý, cờ tắt, bill có người duyệt / chọn tay giữ đại lý, bill đánh giá trước khi đổi được chuyển, lỗi ghi sheet hoàn lại, cả luồng nhiều bill, bill không ghi được về kiểm tra, duyệt lại sau khi sửa, QR đã xác nhận |
| `spec/services/workbook/resolver_spec.rb` | Dùng dòng duy nhất của đại lý trên bill khi TID không cho ra dòng |
| `spec/services/transactions/dealer_reassigner_spec.rb` | Chuyển đại lý, giữ duyệt, từ chối các trường hợp, QR, nạp lại sau khi hoàn lại |
| `spec/services/workbook/ds_header_sync_spec.rb`, `spec/requests/admin/merchant_header_sync_spec.rb`, `spec/tasks/ds_headers_spec.rb` | Đồng bộ header, nút, rake |
| `spec/requests/admin/workbook_review_reasons_spec.rb` | Lý do và link "Cập nhật đại lý của HKD" |
| `spec/services/workbook/seed_spec.rb`, `spec/models/transaction_spec.rb`, `spec/models/app_setting_spec.rb`, `spec/models/settings_form_spec.rb`, `spec/requests/settings_spec.rb`, `spec/services/workbook/write_review_lock_spec.rb` | Seed, chuyển trạng thái, cờ, khoá ghi |

Kết quả gần nhất (17/10/2026, trong container `hellosmc-web-1`): **1273 ví dụ, 2 lỗi**. Hai lỗi ở `spec/requests/remitter_transfers_spec.rb:16` và `:30` cũng lỗi trên `main` (`233bdcd`), không do thay đổi này.

Chạy spec: `docker exec -e RAILS_ENV=test hellosmc-web-1 bash -lc 'cd /app && bundle exec rspec <file>'`.
