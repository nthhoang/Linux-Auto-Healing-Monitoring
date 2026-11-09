# Linux Auto-Healing & Real-Time Monitoring

Hệ thống giám sát và **tự phục hồi** dịch vụ trên Linux (Ubuntu 24.04) bằng 100% mã nguồn mở:
Docker Compose, Prometheus, Alertmanager, Loki, Promtail, Grafana, systemd và ChatOps qua Telegram.

Chu trình khép kín: **Detect → Alert → Heal → Log → Recover**.

## Kiến trúc: hai tầng phòng thủ, mỗi thành phần một nhiệm vụ

```text
HOST (Ubuntu)
 ├─ Tầng 1  heal.sh  (systemd: heal-nginx.service)   -> restart nhanh (~15s), có Circuit Breaker
 │                                                      độc lập với Docker nên vẫn sống khi stack lỗi
 └─ Docker Compose (mạng "monitoring" 172.28.0.0/16, 10 container)
      ├─ nginx            ứng dụng demo (:8080, /health, /nginx_status)
      ├─ nginx-exporter · node-exporter · cadvisor     thu thập metric (ứng dụng · host · container)
      ├─ prometheus       lưu metric + đánh giá luật cảnh báo
      ├─ alertmanager     định tuyến cảnh báo -> Telegram (người) và webhook (auto-healer)
      ├─ auto-healer      Tầng 2: chẩn đoán nguyên nhân (RCA), rollback cấu hình, ChatOps
      └─ promtail -> loki -> grafana      log + dashboard
```

| Thành phần | Nhiệm vụ duy nhất | Tin Telegram nó gửi |
|---|---|---|
| **heal.sh** (Tầng 1) | Container chết/không phản hồi -> `docker restart` tối đa `MAX_RESTARTS` lần, quá thì mở Circuit Breaker | `[WATCHDOG]` DOWN / RECOVERED / CRITICAL |
| **Alertmanager** | Báo cho người biết Prometheus phát hiện gì | `[ALERT]` FIRING / RESOLVED |
| **auto-healer** (Tầng 2) | Chỉ vào cuộc khi `NginxDown` **vẫn còn firing**: RCA, rollback cấu hình, khuyến nghị tài nguyên, ChatOps | `[AUTO-HEALER]` mô tả hành động đã làm |

Nguyên tắc: không có hai thành phần cùng làm một việc. Restart đơn thuần thuộc Tầng 1; chẩn đoán/rollback thuộc Tầng 2;
cảnh báo cho người thuộc Alertmanager; CPU/RAM chỉ **khuyến nghị**, không restart.

## Cài đặt (một lệnh)

```bash
cp .env.example .env     # điền TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, GRAFANA_ADMIN_PASSWORD
./install.sh
```

`.env` là **cấu hình duy nhất** (docker compose, heal.sh và systemd cùng đọc). Không commit file này.

| Dịch vụ | URL | Ghi chú |
|---|---|---|
| Nginx demo | http://localhost:8080 | `/health` |
| Grafana | http://localhost:3000 | tài khoản trong `.env` |
| Prometheus / Alertmanager / Loki / auto-healer / exporters | `127.0.0.1` | chỉ truy cập từ máy chạy hệ thống |

## Kịch bản sự cố (cũng là kịch bản demo)

Một công cụ duy nhất: `scripts/chaos_test.sh`. Mỗi chế độ là một "hồi", kiểm chứng một khả năng khác nhau:

| Hồi | Lệnh | Sự cố | Ai xử lý | Kết quả |
|---|---|---|---|---|
| 0 | `--preflight` | (không) | | Kiểm tra mọi thứ khỏe + gửi tin Telegram thử |
| 1 | `--kill-process` | Container chết | Tầng 1 heal.sh | Phục hồi ≈ 15 s |
| 2 | `--stress-cpu` | CPU quá tải | Alertmanager + auto-healer | Cảnh báo, **không** restart |
| 3 | `--corrupt-config` | Sai cú pháp `nginx.conf` | Tầng 2 auto-healer | RCA phát hiện `[emerg]` -> rollback |
| 4 | `--corrupt-config --manual` | Sai cấu hình khi Auto-Heal đã tắt | Con người (nút ChatOps) | Circuit Breaker mở -> bấm Rollback |

## ChatOps (Telegram, hai chiều)

Sáu nút: Khởi động lại Nginx · Xem 20 dòng log · Rollback cấu hình · Health Check · Trạng thái container · Bật/Tắt Auto-Heal.
Chỉ chat ID khai báo trong `.env` mới được bấm.

## Điều chỉnh ngưỡng

```bash
./scripts/alert_config.sh --fail-threshold 5 --check-interval 3 --max-restarts 3 --cpu-threshold 90 --restart
```

## Bảo mật (đã xử lý và còn lại)

Đã xử lý: secret nằm trong `.env` (gitignore), `alertmanager.yml` sinh từ template, mật khẩu Grafana bắt buộc đặt,
Prometheus/Alertmanager/Loki/auto-healer/exporter chỉ lắng nghe `127.0.0.1`, ChatOps whitelist chat ID, ACL cho `/nginx_status`.
Còn lại (đã nêu trong báo cáo): auto-healer và Promtail mount `docker.sock`, cAdvisor `privileged`, webhook chưa có shared secret, image dùng tag `:latest`.

# demo
1. chay full container, server dang chay, heal-nginx.service dang chay, show he thong dang hoat dong binh thuong
- kiem tra heal-nginx.service dang chay: sudo systemctl status heal-nginx.service
- xem log cua heal-nginx.service: sudo journalctl -u heal-nginx.service -f
- chay full container: docker compose up -d --build
- xem server dang chay http://localhost:8080/
- xem promethus dang thu thap http://localhost:9090/targets
- xem promethus alert http://localhost:9090/alerts
- xem alertmangager localhost:9093
- xem grafana http://localhost:3000/
- xem telegram da khoi dong auto-healer 

2. tat nginx va quan sat phuc hoi bang watchdog
- docker stop nginx
- truy cap vao thay server bi loi 
- vao grafana thay server down
- truy cap vao log watchdog thay no dang phuc hoi
- vao telegram xem thong bao
- quay tro lai grafana va server thay da on 

3. lam tang CPU va chi khuyen nghi de xuat xu ly
- chay kich ban demo ./scripts/chaos_test.sh --stress-cpu
- vao grafana thay cpu tang len
- vao promethus alert thay high cpu dang firing
- vao alertmangager thay no da gui thong bao
- vao telegram xem thong bao
- sau do script tu dong don cpu 
- quan sat nguoc lai thong bao telegram, alertmanger, promethus alert, va grafana

4. demo chi phuc hoi bang watchdog la khong du can phai co autohealer de xu ly
- them dong loi vao config 
- vao telegram tat auto healer
- stop server
- quan sat server grafana da bi down
- vao log watchdog thay no restart khong duoc va gui thong bao tele
- xem alertmanager da gui thong bao cho tele va auto-healer
- no van khong chay lai duoc vi loi cau hinh 
- bat lai auto-healer thay no rollback config trong code 
- quan sat thay tele gui thong bao phuc hoi thanh cong va server va grafana phuc hoi.
