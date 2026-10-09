# Spec: một quy tắc phí cho cả MB và Napas

Trạng thái: đã implement. Một quy tắc được gắn hộ và loại thẻ cùng lúc. `base_fee_rate` chọn sheet. `card_base_fee_rate`, nếu có, đưa vào công thức cột C và E. Cột D vẫn là `dealer_rate` của quy tắc đó. Không có phí gốc theo thẻ thì công thức dùng `base_fee_rate` như trước.

Phạm vi: file Kết toán theo phí gốc và form `/admin/fee_rules/new`. Không đổi snapshot lúc duyệt giao dịch. Cách tính tiền trên giao dịch theo phí gốc theo thẻ nằm ở `SPEC_TINH_PHI_THEO_THE.md`. Không đổi thứ tự chọn quy tắc của `FeeRules::Resolver`.

## 1. Root cause

Quy tắc MB `0,88` / `1,20` và quy tắc Napas `0,88` / `1,20` là hai bản ghi cùng mức “chỉ theo loại thẻ”. Export không đọc snapshot trên giao dịch cho thẻ `mb` và `napas`. Export tìm quy tắc còn hiệu lực tại `transaction_at`, có ghi đúng `card_type_id` của giao dịch, rồi lấy mức cụ thể nhất. Cùng mức thì số ưu tiên nhỏ hơn thắng.

Một quy tắc gắn cả hai loại thẻ, không gắn hộ, nằm cùng mức “chỉ theo loại thẻ”. Cả giao dịch MB và giao dịch Napas đều thấy quy tắc đó, vì danh sách loại thẻ có id của từng thẻ. Trước thay đổi này, resolver đã có test cho cách chọn đó. File xuất chưa có test, nên chưa khóa được ba việc cùng lúc: cả hai dòng vào sheet của hộ, công thức và cột D lấy từ quy tắc chung, snapshot trên giao dịch giữ nguyên.

Tổ hợp dễ làm sai số là gắn nhiều hộ và MB/Napas trên cùng một quy tắc. Mức đó là “HKD + loại thẻ”, thắng quy tắc MB chung. Lần xuất sau dùng phí của quy tắc đó cho mọi hộ đã tick, kể cả giao dịch đã duyệt. Sheet của hộ và phí thẻ là hai việc, nên phải là hai quy tắc.

Một hộ cộng một loại thẻ vẫn là mức cụ thể hợp lệ. Đó là cách gắn phí riêng cho đúng một hộ và đúng một loại thẻ, và resolver đang ưu tiên mức này.

## 2. Solution

Tạo hai quy tắc khi muốn sheet của hộ và phí MB/Napas:

| Quy tắc | Hộ | Loại thẻ | Việc lúc xuất |
|---|---|---|---|
| Phí gốc của hộ | một hoặc nhiều hộ | để trống | Chọn sheet `1,21` / `1,17` / `1,15` |
| Phí thẻ | để trống | `mb` và `napas` | Công thức cột C, E và cột D |

Quy tắc phí thẻ dùng một cặp số cho mọi loại thẻ đã tick. Phí gốc `0,88` và phí đại lý `1,20` cho ra công thức `0.88%` và cột D = `0.012`. Ưu tiên của quy tắc này nhỏ hơn quy tắc chỉ MB hoặc chỉ Napas nếu cả hai cùng hiệu lực và cùng mức.

Sheet vẫn lấy từ quy tắc được gắn đúng hộ, loại thẻ để trống hoặc có Thẻ thường, phí gốc đúng một trong ba mức sheet, còn hiệu lực tại `transaction_at`. Quy tắc MB/Napas không chọn sheet. Quy tắc hệ thống `1,21` không gắn hộ thì không phải sheet của hộ.

Từ `SPEC_TINH_PHI_THEO_THE.md`, file xuất đọc số đã lưu trên giao dịch (`applied_card_base_fee_rate` hoặc `applied_base_fee_rate`, `applied_dealer_rate`, và mức hộ lưu trong `calculation_data`), không tra lại quy tắc lúc xuất. Phần "Việc lúc xuất" trong bảng trên mô tả quy tắc nào cung cấp các số đó lúc tính tiền.

Một quy tắc được tick hộ và loại thẻ cùng lúc. Field **Phí gốc theo thẻ** hiện khi có ít nhất một loại thẻ. Phí gốc của quy tắc đó chọn sheet nếu đúng `1,21` / `1,17` / `1,15`. Phí gốc theo thẻ đưa vào công thức. Không nhập phí gốc theo thẻ thì công thức dùng phí gốc.

## 3. Test case

### 3.1 Xuất file, một quy tắc cho MB và Napas

Dữ liệu:

- Hộ có quy tắc không gắn loại thẻ, phí gốc `1,21`, phí đại lý `1,40`.
- Một quy tắc không gắn hộ, gắn `mb` và `napas`, phí gốc `0,88`, phí đại lý `1,20`, ưu tiên `40`.
- Quy tắc chỉ `mb` ở ưu tiên `100` vẫn tồn tại. Quy tắc ưu tiên `40` thắng vì cùng mức và số nhỏ hơn.
- Hai giao dịch đã duyệt của cùng hộ, `transaction_at` trong thời gian hiệu lực. Một giao dịch `mb`, một giao dịch `napas`. Cả hai được tạo trước `SPEC_TINH_PHI_THEO_THE.md` nên đang chốt phí gốc `1,21` và phí đại lý `1,40`. Giao dịch tạo sau đó chốt `applied_card_base_fee_rate` `0,88` và `applied_dealer_rate` `1,20`. File xuất không đọc hai số này cho `mb` và `napas`.

Kỳ vọng của `Exports::KetToanPhiGocLayout.partition`:

| Giao dịch | Sheet | Công thức | Cột D | Snapshot sau xuất |
|---|---|---|---|---|
| `mb` | `1,21` | `0.88%` | `0.012` | phí gốc `0.0121`, phí đại lý `0.014` |
| `napas` | `1,21` | `0.88%` | `0.012` | phí gốc `0.0121`, phí đại lý `0.014` |

Không có dòng trong `skipped`.

### 3.2 Form và validation

| Lựa chọn | Kết quả |
|---|---|
| Hai hộ, không loại thẻ | Lưu được. Mức áp dụng là HKD. |
| `mb` và `napas`, không hộ | Lưu được. Placeholder `0,88` / `1,2`. |
| Nhiều hộ và một hoặc nhiều loại thẻ, có phí gốc theo thẻ | Lưu được. Xuất file lấy sheet từ phí gốc và công thức từ phí gốc theo thẻ. |

## 4. Ngoài phạm vi

- Không gộp rollback của `fee_rule_merchants` và `fee_rule_card_types` thành giữ đủ nhiều hộ và nhiều loại thẻ. `down` giữ một hộ và một loại thẻ. Lùi migration là bỏ multi-select, nên không đổi UI để phục vụ rollback.
- Không đổi quy tắc #6 ngoài form này. Ngày hiệu lực của quy tắc đó vẫn quyết định sheet của giao dịch cũ.
- Không thêm sheet `MBV`.
