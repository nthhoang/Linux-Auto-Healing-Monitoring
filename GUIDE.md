# Linux Auto-Healing Monitoring — Hướng dẫn triển khai từ A-Z

## 0. Mục tiêu dự án

Xây dựng một hệ thống **Linux Server Monitoring + Auto-Healing** hoàn chỉnh, chạy trên Ubuntu bằng Docker, đáp ứng đúng chu trình:

```
Cấu hình → Deploy → Monitoring → Testing → Failure → Detect → Alert → Healing → Recovery
```

Checklist cuối cùng cần đạt được:

- [ ] `/health` endpoint hoạt động
- [ ] Prometheus targets đều **UP**
- [ ] Grafana có dashboard hiển thị số liệu
- [ ] Loki nhận được log
- [ ] Telegram nhận được cảnh báo
- [ ] heal-daemon (heal.sh) tự động phục hồi khi Nginx chết
- [ ] Test scenario chạy tự động chứng minh toàn bộ chu trình

## 1. Kiến trúc tổng quan

```
Ubuntu 24.04
  └── Docker
        ├── nginx              (ứng dụng demo, expose :8080)
        ├── nginx-exporter      (metrics Nginx -> Prometheus)
        ├── node-exporter       (metrics CPU/RAM/disk của máy)
        ├── cadvisor            (metrics container)
        ├── prometheus          (thu thập + đánh giá alert rules, :9090)
        ├── alertmanager        (định tuyến alert -> Telegram, :9093)
        ├── loki                (lưu trữ log, :3100)
        ├── promtail            (đẩy log container -> loki)
        └── grafana             (dashboard, :3000)

heal.sh (chạy trên HOST qua systemd, không nằm trong Docker)
  └── liên tục gọi curl http://localhost:8080/health
        └── nếu fail liên tiếp N lần -> docker restart nginx -> báo Telegram
```

File/thư mục trong project (đã tạo sẵn đầy đủ, không cần gõ tay):

```
linux-autohealing-project/
├── GUIDE.md                 <- chính là file này
├── docker-compose.yml       <- "nhạc trưởng" điều phối toàn bộ 9 service
├── install.sh                <- triển khai 1 lệnh
├── .gitignore
├── nginx/{nginx.conf, html/index.html}
├── prometheus/{prometheus.yml, alert_rules.yml}
├── alertmanager/alertmanager.yml
├── loki/loki-config.yml
├── promtail/promtail-config.yml
├── grafana/provisioning/{datasources,dashboards}/...
└── scripts/{heal.sh, heal.env.example, alert_config.sh, test_scenario.sh}
```

Toàn bộ các file cấu hình trên **đã được viết sẵn, đã kiểm tra cú pháp YAML/JSON và cú pháp Bash (bash -n + shellcheck)**. Bạn chỉ cần giải nén, điền token Telegram, và chạy theo từng giai đoạn bên dưới — không cần tự viết lại.

---

## Giai đoạn 0 — Chuẩn bị: tạo Telegram Bot để nhận cảnh báo

1. Mở Telegram, tìm **@BotFather**, bấm Start.
2. Gửi lệnh `/newbot`, đặt tên hiển thị và username (username phải kết thúc bằng `bot`, ví dụ `vku_autoheal_bot`).
3. BotFather trả về một **bot token** dạng: `123456789:ABCdefGhIJKlmNoPQRsTUVwxyz`. Lưu lại.
4. Tìm chính bot bạn vừa tạo (theo username), bấm **Start**, gửi một tin nhắn bất kỳ (ví dụ "hi").
5. Lấy **chat_id** bằng lệnh sau (thay `<TOKEN>` bằng token ở bước 3):

   ```bash
   curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates"
   ```

   Trong kết quả JSON trả về, tìm `"chat":{"id":XXXXXXXXX ...}` — số đó chính là `chat_id`.

6. Kiểm tra nhanh token + chat_id đã đúng chưa:

   ```bash
   curl -s -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
     --data-urlencode "chat_id=<CHAT_ID>" \
     --data-urlencode "text=Test message from Linux Auto-Healing project"
   ```

   Nếu điện thoại nhận được tin nhắn "Test message..." từ bot -> đã đúng.

Giữ token + chat_id này lại, sẽ dùng ở Giai đoạn 6.

---

## Giai đoạn 1 — Cài Docker Engine trên Ubuntu 24.04

```bash
# 1. Gỡ các bản Docker cũ (nếu trước đây từng cài qua apt mặc định của Ubuntu)
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y $pkg 2>/dev/null
done

# 2. Cài các gói cần thiết + thêm GPG key chính thức của Docker
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# 3. Thêm repository chính thức của Docker
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

# 4. Cài Docker Engine + Compose plugin
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 5. Kiểm tra Docker chạy được chưa
sudo docker run hello-world
```

Cho phép chạy `docker` **không cần sudo** (bắt buộc để `install.sh` sau này chạy trơn tru):

```bash
sudo usermod -aG docker $USER
newgrp docker
```

> `newgrp docker` mở một sub-shell mới với quyền group đã cập nhật. Nếu vẫn bị lỗi "permission denied" khi chạy docker, hãy **đăng xuất rồi đăng nhập lại** (hoặc khởi động lại máy) để chắc chắn quyền group được áp dụng.

Kiểm tra lại — cả 3 lệnh phải chạy được, không cần sudo, không báo lỗi:

```bash
docker --version
docker compose version
docker ps
```

---

## Giai đoạn 2 — Giải nén project & mở bằng VS Code

```bash
cd ~
unzip linux-autohealing-project.zip   # hoặc giải nén bằng GUI
cd linux-autohealing-project
code .
find . -type f | sort   # xem nhanh cấu trúc
```

---

## Giai đoạn 3 — Chạy Nginx (nền tảng đầu tiên)

Chỉ khởi động một service duy nhất để hiểu luồng cơ bản trước:

```bash
docker compose up -d nginx
docker compose ps
curl http://localhost:8080/           # phải trả về trang HTML demo
curl http://localhost:8080/health     # phải trả về "OK"
```

Mở trình duyệt tới `http://localhost:8080` để xem trang demo.

**Ý nghĩa:** `nginx/nginx.conf` định nghĩa 3 location: `/` (trang demo), `/health` (cho heal.sh và Prometheus kiểm tra sống/chết), `/nginx_status` (cho nginx-exporter đọc số liệu, chỉ mở trong mạng nội bộ Docker qua subnet `172.28.0.0/16` đã khai báo trong `docker-compose.yml`).

---

## Giai đoạn 4 — Thêm các Exporter (thu thập chỉ số)

```bash
docker compose up -d nginx-exporter node-exporter cadvisor
docker compose ps

curl -s http://localhost:9113/metrics | head -20   # nginx-exporter
curl -s http://localhost:9100/metrics | head -20   # node-exporter
curl -s http://localhost:8081/metrics | head -20   # cadvisor (map cổng 8081->8080)
```

Nếu cả 3 lệnh đều in ra text dạng `# HELP ...` / `# TYPE ...` thì exporter đang chạy đúng.

> **Lưu ý về cAdvisor trên cgroup v2 (mặc định của Ubuntu 24.04):** container cần chạy với `privileged: true` (đã cấu hình sẵn) thì mới đọc được đầy đủ chỉ số CPU/RAM theo container. Image dùng là `ghcr.io/google/cadvisor:v0.60.5` — registry mới của dự án (đã chuyển từ `gcr.io` sang `ghcr.io` từ bản v0.56.0). Không đổi lại thành `gcr.io/cadvisor/cadvisor:latest` vì tag đó rất cũ và thiếu số liệu trên cgroup v2.

---

## Giai đoạn 5 — Prometheus (thu thập & đánh giá metric)

```bash
docker compose up -d prometheus
```

Mở `http://localhost:9090/targets` — phải thấy 4 target: `prometheus`, `nginx`, `node`, `cadvisor` đều **UP** (xanh). Thử PromQL tại `http://localhost:9090/graph`: gõ `up`, phải trả về 4 dòng giá trị = 1.

**Ý nghĩa:** `prometheus.yml` khai báo 4 scrape job (mỗi 10s) và trỏ `alerting.alertmanagers` tới `alertmanager:9093`. `alert_rules.yml` định nghĩa 3 rule: `NginxDown` (up{job="nginx"}==0 trong >15s), `HighCPUUsage` (>85% trong >1 phút), `HighMemoryUsage` (>90% trong >1 phút).

---

## Giai đoạn 6 — Alertmanager + Telegram (đường dây cảnh báo)

Điền token/chat_id lấy được ở Giai đoạn 0:

```bash
cp scripts/heal.env.example scripts/heal.env
nano scripts/heal.env   # hoặc mở bằng VS Code, điền 2 dòng đầu
```

```
TELEGRAM_BOT_TOKEN=123456789:ABCdefGhIJKlmNoPQRsTUVwxyz
TELEGRAM_CHAT_ID=987654321
```

Ghi token vào `alertmanager.yml` (làm tay cho bước test riêng lẻ này; khi dùng `install.sh` ở Giai đoạn 10 việc này sẽ **tự động**):

```bash
source scripts/heal.env
sed -i "s|__TELEGRAM_BOT_TOKEN__|${TELEGRAM_BOT_TOKEN}|g; s|__TELEGRAM_CHAT_ID__|${TELEGRAM_CHAT_ID}|g" alertmanager/alertmanager.yml
docker compose up -d alertmanager
```

Mở `http://localhost:9093` (chưa có alert nào vì Nginx đang khoẻ — bình thường).

**Test cảnh báo thật:**

```bash
docker stop nginx
```

Đợi ~20-30 giây, Telegram sẽ nhận `🚨 FIRING — NginxDown`. Khởi động lại (heal.sh chưa chạy ở bước này nên phải làm tay):

```bash
docker start nginx
```

Vài chục giây sau sẽ nhận thêm `✅ RESOLVED — NginxDown`.

---

## Giai đoạn 7 — Loki + Promtail (tổng hợp log)

```bash
docker compose up -d loki promtail
curl -s http://localhost:3100/ready    # phải trả về "ready"
```

> **Lưu ý:** Promtail đã được Grafana công bố ngừng phát triển (EOL) từ 3/2026, khuyến nghị Grafana Alloy cho hệ thống mới. Project này vẫn dùng Promtail vì đúng cấu trúc nhóm đã lên kế hoạch, YAML đơn giản hơn Alloy (Alloy dùng cú pháp river/HCL khác biệt), và image vẫn hoạt động bình thường — chỉ không còn nhận tính năng mới. Có thể ghi chú điều này trong báo cáo như hướng phát triển tiếp theo.

**Ý nghĩa:** `promtail-config.yml` dùng `docker_sd_configs` để tự động phát hiện mọi container qua `/var/run/docker.sock` và đẩy log vào Loki tại `http://loki:3100/loki/api/v1/push`, không cần khai báo tay từng container.

---

## Giai đoạn 8 — Grafana (trực quan hoá)

```bash
docker compose up -d grafana
```

Mở `http://localhost:3000`, đăng nhập `admin` / `admin` (có thể bấm "Skip" khi được hỏi đổi mật khẩu).

Vào **Dashboards** — dashboard **"Server Monitoring - Auto Healing"** đã tự động provision sẵn: CPU Usage, RAM Usage, Nginx Status (UP/DOWN), Running Containers, biểu đồ CPU & RAM theo thời gian, biểu đồ Requests/sec.

Panel Requests/sec trống tới khi có traffic thật:

```bash
for i in $(seq 1 50); do curl -s http://localhost:8080/ > /dev/null; done
```

Kiểm tra Loki: vào **Explore** → chọn datasource **Loki** → query `{container="nginx"}` → phải thấy log Nginx hiện ra.

**Ý nghĩa:** `datasource.yml` tự khai báo 2 datasource (Prometheus, Loki) với `uid` cố định; `server-monitoring.json` là dashboard nạp sẵn qua provisioning, không cần vẽ panel bằng tay.

---

## Giai đoạn 9 — heal.sh (daemon tự phục hồi) chạy qua systemd

`scripts/heal.sh` gọi `curl http://localhost:8080/health` mỗi `CHECK_INTERVAL` giây (mặc định 5s). Sau `FAIL_THRESHOLD` lần fail liên tiếp (mặc định 3, ~15s), nó chạy `docker restart nginx` và gửi Telegram; khi health check thành công trở lại, gửi thêm "RECOVERED".

Test thủ công trước (Ctrl+C để dừng):

```bash
chmod +x scripts/*.sh
source scripts/heal.env
./scripts/heal.sh
```

Ở terminal khác, thử `docker stop nginx`, quan sát terminal heal.sh — sau ~15s sẽ thấy log restart container. Ctrl+C dừng, rồi cài làm systemd service để chạy nền và tự khởi động cùng hệ thống:

```bash
CURRENT_USER="$(whoami)"
PROJECT_DIR="$(pwd)"

sudo tee /etc/systemd/system/heal-nginx.service > /dev/null <<EOF
[Unit]
Description=Auto-healing watchdog for Nginx (Linux Auto-Healing Project)
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=${CURRENT_USER}
WorkingDirectory=${PROJECT_DIR}
EnvironmentFile=${PROJECT_DIR}/scripts/heal.env
ExecStart=${PROJECT_DIR}/scripts/heal.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable heal-nginx.service
sudo systemctl start heal-nginx.service
sudo systemctl status heal-nginx.service    # phải hiện "active (running)"
```

> Đoạn này chính là những gì `install.sh` ở Giai đoạn 10 làm tự động — làm tay một lần ở đây để hiểu cơ chế, các lần deploy sau dùng `install.sh` cho nhanh.

---

## Giai đoạn 10 — Triển khai một lệnh (install.sh)

```bash
./install.sh
```

`install.sh` tự động, theo đúng thứ tự: (1) kiểm tra Docker/Compose sẵn sàng, (2) kiểm tra `scripts/heal.env` đã có token chưa — nếu chưa thì tạo file mẫu và dừng lại để bạn điền, (3) ghi token vào `alertmanager.yml`, (4) cấp quyền thực thi cho script, (5) `docker compose up -d` khởi động cả 9 service, (6) cài + khởi động `heal-nginx.service`, (7) in toàn bộ URL truy cập.

Chạy lại lần 2 (ví dụ trên máy khác sau khi `git clone`) vẫn an toàn — không ghi đè token đã điền, không tạo trùng service.

---

## Giai đoạn 11 — Kiểm thử kịch bản demo tự động

```bash
./scripts/test_scenario.sh
```

Script sẽ: in trạng thái ban đầu → `docker stop nginx` giả lập sự cố → theo dõi tối đa 60s xem `/health` tự phục hồi chưa → in trạng thái Prometheus target `nginx` → in trạng thái cuối cùng.

Song song mở **Grafana** (panel "Nginx Status" chuyển xanh→đỏ→xanh) và **Telegram** (nhận `🚨 FIRING`/`🚨 DOWN DETECTED` rồi `✅ RESOLVED`/`✅ RECOVERED`) — đúng chu trình **Deploy → Monitoring → Failure → Detect → Alert → Healing → Recovery** mà đồ án yêu cầu, chạy hoàn toàn tự động, có thể quay video demo trực tiếp từ bước này.

---

## Giai đoạn 12 — Điều chỉnh ngưỡng cảnh báo/auto-heal

Không sửa tay YAML — dùng `scripts/alert_config.sh`:

```bash
./scripts/alert_config.sh --fail-threshold 5 --check-interval 3 --cpu-threshold 90 --restart
```

Xem tất cả tuỳ chọn: `./scripts/alert_config.sh --help`

---

## Checklist trước khi nộp / bảo vệ đồ án

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/health      # -> 200
curl -s http://localhost:9090/api/v1/targets | grep -o '"health":"[a-z]*"' # -> toàn bộ "up"
curl -s http://localhost:3100/ready                                       # -> ready
sudo systemctl is-active heal-nginx.service                               # -> active
docker compose ps                                                         # -> toàn bộ "Up"/"running"
```

## Xử lý sự cố thường gặp

| Triệu chứng | Nguyên nhân thường gặp | Cách xử lý |
|---|---|---|
| `docker: permission denied` | User chưa thuộc group `docker`, hoặc chưa đăng nhập lại sau `usermod` | `sudo usermod -aG docker $USER` rồi **logout/login lại** |
| Target `cadvisor` màu đỏ/DOWN | cgroup v2 chặn quyền đọc | `docker compose logs cadvisor`; đảm bảo `privileged: true` còn nguyên trong docker-compose.yml |
| Không nhận được Telegram | Token/chat_id sai, hoặc chưa `/start` chat với bot | Chạy lại lệnh test ở Giai đoạn 0 bước 6 |
| Grafana panel "No data" | Chưa có datasource, hoặc chưa có traffic (Requests/sec) | Connections → Data sources kiểm tra Prometheus/Loki; tạo traffic thử bằng vòng lặp curl |
| `heal-nginx.service` là `failed` | Sai đường dẫn trong unit file, hoặc `heal.env` thiếu | `sudo journalctl -u heal-nginx.service -n 50` xem log lỗi cụ thể |
| `docker compose up` lỗi pull image | Máy chưa có mạng ra ngoài, hoặc registry chặn | `docker pull <tên-image>` thử riêng lẻ để xác định image nào lỗi |

## Phụ lục — Bảng cổng (port) sử dụng

| Service | Port trên host | Ghi chú |
|---|---|---|
| nginx | 8080 | Trang demo + `/health` |
| nginx-exporter | 9113 | Metrics Nginx |
| node-exporter | 9100 | Metrics host |
| cadvisor | 8081 | Metrics container (nội bộ dùng cổng 8080) |
| prometheus | 9090 | UI + API |
| alertmanager | 9093 | UI |
| loki | 3100 | API push/query log |
| grafana | 3000 | Dashboard |
