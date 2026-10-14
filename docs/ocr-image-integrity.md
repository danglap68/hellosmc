# Kiểm tra dấu hiệu chỉnh sửa ảnh bill

Đây là lớp sàng lọc rủi ro bằng model thị giác trong lượt OCR hiện có. Nó không xác thực bill, không chứng minh ảnh do AI tạo, và không xác nhận tiền đã vào tài khoản.

## Kết quả đọc ảnh

Mỗi document mới phải có `image_integrity` gồm `status` và tối đa hai mô tả bằng chứng ngắn:

- `no_visible_signs`: chưa thấy bất thường cụ thể; không có nghĩa là bill thật.
- `suspicious`: thấy bất thường cụ thể tại vùng quan trọng như số tiền, ngày, tên HKD hoặc số lô; cần nêu vùng ảnh và dấu hiệu.
- `uncertain`: chất lượng ảnh không cho phép đánh giá vùng quan trọng; cần người kiểm tra.

Các dữ liệu OCR cũ không có trường này được đọc là `not_assessed`, không được gắn nhãn đã kiểm tra. Câu trả lời OCR mới bỏ trường này bị xử lý như output sai schema. Các fixtures kiểm thử có kết quả mô phỏng; không phải kết quả phát hiện trên ảnh thật.

Prompt yêu cầu không coi bóng đổ, giấy in nhiệt, độ mờ, phối cảnh, screenshot hoặc nén Telegram đơn thuần là bằng chứng giả mạo. Không xuất phần trăm xác suất ảnh AI, và không gán kết luận gian lận cho người gửi.

## Quyết định xử lý

- Model chính hoặc validator báo rủi ro đều đưa bill về `needs_review`; đồng thuận về số tiền không xóa cảnh báo đó.
- Không tự duyệt hoặc tự ghi sheet khi còn cảnh báo. Người kiểm tra có thể đối chiếu chứng từ gốc và quyết định theo luồng duyệt hiện có.
- Dấu hiệu rủi ro trong ảnh đi kèm album cũng chặn tự duyệt bill kết của album. Ảnh không đọc được nhưng đáng ngờ được giữ để kiểm tra.
- Chuyển tiền sử dụng cùng kiểm tra và không tự ghi sheet khi có rủi ro.
- Retry giữ rủi ro đã từng phát hiện để tránh việc đọc lại nhiều lần rồi vô tình bỏ qua cảnh báo. Bằng chứng các lượt cũ được lưu trong `vision_history`; retry không thay thế xác minh thủ công.
- Giới hạn hiện có không đổi: một primary và tối đa một validator mỗi lượt, tối đa ba lượt OCR cho mỗi bill. Rủi ro có thể kích hoạt validator trong giới hạn đó; đây không phải cam kết chi phí giữ nguyên.

Các cảnh báo được hiển thị trong “Lý do cần kiểm tra”. Bằng chứng và kết quả từng model nằm trong dữ liệu OCR/lịch sử xử lý. Bill đã duyệt/đã ghi sheet trước khi triển khai không bị tự mở lại hoặc tự thay đổi số tiền.

## Giới hạn và đối soát

Tests xác nhận schema, luồng chặn tự duyệt, lưu bằng chứng, album, chuyển tiền và retry. Chưa đo độ nhạy hoặc tỷ lệ báo nhầm trên bộ ảnh thật/giả đại diện cho bill và ảnh nén Telegram; không coi tests xanh là chứng nhận khả năng nhận diện giả mạo.

Để xác thực giao dịch, cần đối chiếu số tiền, MID/TID, số lô, thời gian và mã giao dịch với dữ liệu độc lập từ POS/ngân hàng. Ảnh có thể trông hoàn toàn hợp lý dù số liệu đã bị thay đổi; lớp thị giác không thay thế được đối soát này.

Tham khảo: [NIST AI 100-4 — Reducing Risks Posed by Synthetic Content](https://www.nist.gov/publications/reducing-risks-posed-synthetic-content-overview-technical-approaches-digital-content).
