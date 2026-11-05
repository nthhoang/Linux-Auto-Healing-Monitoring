# SRE Auto-Healer & Interactive ChatOps Daemon

Microservice điều khiển tự phục hồi và quản trị tương tác 2 chiều (Bi-directional ChatOps) cho hệ thống Linux Monitoring & Auto-Healing.

## Vai trò trong kiến trúc (Tầng 2)
Restart nhanh khi container chết do **heal.sh (Tầng 1, trên host)** đảm nhiệm. Container này chỉ vào cuộc khi cảnh báo
`NginxDown` vẫn còn firing: chẩn đoán nguyên nhân, rollback cấu hình, khuyến nghị CPU/RAM và ChatOps.
Alertmanager gửi tin `[ALERT]`; container này chỉ gửi tin `[AUTO-HEALER]` mô tả hành động (không lặp lại cảnh báo).

## 🎯 Tính năng nổi bật
1. **Event-Driven Auto-Healing:** Tiếp nhận Webhook trực tiếp từ Alertmanager khi Prometheus kích hoạt cảnh báo sự cố.
2. **Root Cause Analysis (RCA):**
   - Phân biệt lỗi cú pháp cấu hình (`[emerg] invalid syntax`) với lỗi treo tiến trình (`crash/stop`).
   - Tự động **Rollback** file cấu hình từ `nginx.conf.bak` khi phát hiện file cấu hình bị lỗi.
   - Cơ chế **Circuit Breaker** chống vòng lặp khởi động lại vô hạn (Crash loop).
3. **ChatOps 2 chiều qua Telegram:**
   - Cung cấp nút bấm tương tác (Inline Keyboard Buttons) trực tiếp trên điện thoại:
     - `[🔄 Khởi động lại Nginx]`
     - `[📋 Xem 20 dòng Logs]`
     - `[↩️ Rollback Cấu hình]`
     - `[🩺 Health Check]`
     - `[📊 Trạng thái Container]`
     - `[⏸️ Bật/Tắt Auto-Heal]`
   - Xác thực bảo mật người gửi lệnh bằng whitelist `TELEGRAM_CHAT_ID`.

## ⚙️ Biến môi trường
- `TELEGRAM_BOT_TOKEN`: Token của bot Telegram.
- `TELEGRAM_CHAT_ID`: ID người dùng hoặc nhóm nhận cảnh báo và có quyền điều khiển.
- `PORT`: Cổng Webhook lắng nghe (mặc định: `5001`).
- `MAX_RESTARTS`: Số lần restart tối đa trước khi mở Circuit Breaker (mặc định: `3`).
- `CONTAINER_NAME`: Tên container mục tiêu cần bảo vệ (mặc định: `nginx`).
- `NGINX_CONF_PATH`: Đường dẫn tới file cấu hình Nginx (mặc định: `/app/nginx_config/nginx.conf`).
- `NGINX_BAK_PATH`: Đường dẫn tới file sao lưu cấu hình chuẩn (mặc định: `/app/nginx_config/nginx.conf.bak`).
