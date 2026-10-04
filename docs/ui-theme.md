# Giao diện Tabler

App dùng Tabler 1.6.1 và Tabler Icons có sẵn trong `vendor/assets/tabler`.
Các component, dropdown, collapse, form và responsive table vẫn dùng Tabler.

`app/assets/stylesheets/application.css` chứa token sáng/tối và style dùng chung.
Giao diện quản trị ưu tiên bảng dữ liệu: sidebar trung tính, navigation đang chọn
có nền xanh nhẹ, card dùng border thay vì shadow, số tiền dùng tabular numerals.
Màu trạng thái có cặp foreground/background riêng cho mỗi theme để dễ đọc.
Style component được giới hạn trong `.app-ui`; layout email dùng CSS riêng.

## Chọn giao diện

`layouts/_theme_switcher.html.erb` cung cấp ba nút: Sáng, Tối, Hệ thống.
Nút nằm ở header của admin và các trang đăng nhập/đặt lại mật khẩu.
Trên mobile, nhãn rút gọn thành icon nhưng vẫn giữ accessible name và tooltip.

`app/javascript/theme.js` đặt `data-bs-theme` trên `<html>` trước khi CSS tải.
Lựa chọn lưu trong localStorage với key `hellosmc-theme`; mặc định là `system`.
Chế độ hệ thống theo `prefers-color-scheme` và cập nhật khi hệ điều hành đổi theme.
Script xử lý điều hướng Turbo, đồng bộ giữa các tab và trường hợp storage bị chặn.
Theme chỉ là tùy chọn trình duyệt, không ghi vào tài khoản hoặc database.

## Kiểm tra

```sh
node --test spec/javascript/theme_test.cjs
bundle exec rspec spec/requests/admin_pages_spec.rb spec/requests/admin/transactions_spec.rb spec/requests/role_restrictions_spec.rb spec/requests/authentication_spec.rb spec/system/ocr_review_flow_spec.rb spec/system/fee_rule_crud_spec.rb spec/system/transaction_approval_spec.rb
```

Khi sửa UI, kiểm tra dashboard, bảng giao dịch, form và trang đăng nhập ở cả sáng/tối.
Menu thu gọn ở breakpoint 992px. Bảng rộng cuộn bên trong `.table-responsive`,
không làm tràn toàn trang. Hỗ trợ focus bàn phím, skip link và reduced motion.
