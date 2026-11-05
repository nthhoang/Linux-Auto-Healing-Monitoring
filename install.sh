#!/usr/bin/env bash
# install.sh - Triển khai toàn bộ hệ thống bằng MỘT lệnh.
# Yêu cầu: đã cài Docker Engine + Docker Compose plugin và user thuộc nhóm "docker".
# Cấu hình duy nhất: file .env ở thư mục gốc (xem .env.example).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

echo "===================================================="
echo " Linux Auto-Healing Monitoring - Cài đặt tự động"
echo "===================================================="

# 1. Kiểm tra Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker chưa được cài đặt (xem README.md, mục Yêu cầu)."
    exit 1
fi
if ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose plugin chưa sẵn sàng."
    exit 1
fi
if ! docker ps &> /dev/null; then
    echo "❌ Không chạy được 'docker ps'. User hiện tại có thể chưa thuộc nhóm 'docker'."
    echo "   Chạy: sudo usermod -aG docker \$USER && newgrp docker    (rồi thử lại)"
    exit 1
fi
echo "✔ Docker: $(docker --version)"
echo "✔ Docker Compose: $(docker compose version --short)"

# 2. File .env (cấu hình duy nhất)
if [[ ! -f ".env" ]]; then
    cp .env.example .env
    chmod 600 .env
    echo
    echo "⚠ Chưa có .env — đã tạo từ .env.example."
    echo "  Hãy điền TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, GRAFANA_ADMIN_PASSWORD rồi chạy lại ./install.sh"
    exit 1
fi
chmod 600 .env

set -a
# shellcheck source=/dev/null
source .env
set +a

missing=()
[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]     || missing+=("TELEGRAM_BOT_TOKEN")
[[ -n "${TELEGRAM_CHAT_ID:-}" ]]       || missing+=("TELEGRAM_CHAT_ID")
[[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]] || missing+=("GRAFANA_ADMIN_PASSWORD")
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "❌ File .env đang thiếu: ${missing[*]}"
    exit 1
fi
echo "✔ Đã đọc cấu hình từ .env"

# 3. Tạo alertmanager.yml từ template (token không bao giờ nằm trong Git)
sed "s|__TELEGRAM_BOT_TOKEN__|${TELEGRAM_BOT_TOKEN}|g; s|__TELEGRAM_CHAT_ID__|${TELEGRAM_CHAT_ID}|g" \
    alertmanager/alertmanager.template.yml > alertmanager/alertmanager.yml
echo "✔ Đã tạo alertmanager/alertmanager.yml (đã được .gitignore bảo vệ)"

# 4. Bản sao lưu "last-known-good" của nginx.conf, dùng cho Rollback
if [[ ! -f "nginx/nginx.conf.bak" ]]; then
    cp nginx/nginx.conf nginx/nginx.conf.bak
    echo "✔ Đã tạo nginx/nginx.conf.bak cho cơ chế Rollback"
fi

# 5. Quyền thực thi cho scripts
chmod +x scripts/*.sh

# 6. Khởi động toàn bộ stack (kèm build auto-healer)
echo
echo "-> docker compose up -d --build ..."
docker compose up -d --build
docker pull -q alpine > /dev/null 2>&1 || true   # image dùng cho kịch bản ép tải CPU

echo "-> Chờ hệ thống sẵn sàng (tối đa 90s)..."
ready=false
for _ in $(seq 1 45); do
    if curl -sf -o /dev/null --max-time 2 http://localhost:8080/health \
       && curl -sf -o /dev/null --max-time 2 http://localhost:9090/-/ready; then
        ready=true; break
    fi
    sleep 2
done
[[ "$ready" == true ]] && echo "✔ Nginx và Prometheus đã sẵn sàng" || echo "⚠ Chưa sẵn sàng sau 90s - kiểm tra: docker compose ps"

echo
docker compose ps

# 7. Tầng 1: cài heal.sh làm systemd service (đọc cùng file .env)
echo
echo "-> Cài đặt heal-nginx.service (watchdog Tầng 1)..."
CURRENT_USER="$(whoami)"
sudo tee /etc/systemd/system/heal-nginx.service > /dev/null <<UNIT
[Unit]
Description=Auto-healing watchdog (Tang 1) for Nginx - Linux Auto-Healing Project
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=${CURRENT_USER}
WorkingDirectory=${PROJECT_DIR}
EnvironmentFile=${PROJECT_DIR}/.env
ExecStart=${PROJECT_DIR}/scripts/heal.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable heal-nginx.service > /dev/null 2>&1
sudo systemctl restart heal-nginx.service

echo
echo "===================================================="
echo " ✅ HOÀN TẤT"
echo "===================================================="
echo " Web demo     : http://localhost:8080   (health: /health)"
echo " Grafana      : http://localhost:3000   (${GRAFANA_ADMIN_USER:-admin} / mật khẩu trong .env)"
echo " Prometheus   : http://localhost:9090   (chỉ truy cập từ máy này)"
echo " Alertmanager : http://localhost:9093   (chỉ truy cập từ máy này)"
echo " Tầng 1       : sudo systemctl status heal-nginx.service"
echo " Tầng 2       : docker compose logs -f auto-healer"
echo
echo " Kiểm tra trước demo : ./scripts/chaos_test.sh --preflight"
echo " Kịch bản sự cố      : ./scripts/chaos_test.sh --help"
echo "===================================================="
