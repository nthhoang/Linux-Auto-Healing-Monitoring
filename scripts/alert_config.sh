#!/usr/bin/env bash
# alert_config.sh - Chỉnh ngưỡng cảnh báo / auto-heal mà không cần sửa tay từng file (cấu hình nằm trong .env).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
RULES_FILE="${PROJECT_DIR}/prometheus/alert_rules.yml"

usage() {
    cat <<EOF
Usage: $0 [options]
  --fail-threshold N   Số lần health-check fail liên tiếp trước khi heal.sh restart container (mặc định: 3)
  --check-interval N   Số giây giữa mỗi lần health-check (mặc định: 5)
  --max-restarts N     Số lần restart tối đa trước khi mở Circuit Breaker (mặc định: 3)
  --cpu-threshold N    Ngưỡng % CPU để Prometheus bắn cảnh báo HighCPUUsage (mặc định: 85)
  --restart            Khởi động lại heal-nginx.service, auto-healer và reload Prometheus sau khi đổi cấu hình
  -h, --help            Hiển thị hướng dẫn này
EOF
}

RESTART=false
CPU_THRESHOLD=""
FAIL_THRESHOLD=""
CHECK_INTERVAL=""
MAX_RESTARTS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fail-threshold) FAIL_THRESHOLD="$2"; shift 2 ;;
        --check-interval) CHECK_INTERVAL="$2"; shift 2 ;;
        --max-restarts) MAX_RESTARTS="$2"; shift 2 ;;
        --cpu-threshold) CPU_THRESHOLD="$2"; shift 2 ;;
        --restart) RESTART=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Không nhận diện được tùy chọn: $1"; usage; exit 1 ;;
    esac
done

[[ -f "$ENV_FILE" ]] || cp "${PROJECT_DIR}/.env.example" "$ENV_FILE"

update_env() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

if [[ -n "$FAIL_THRESHOLD" ]]; then
    update_env "FAIL_THRESHOLD" "$FAIL_THRESHOLD"
    echo "✔ FAIL_THRESHOLD = $FAIL_THRESHOLD"
fi

if [[ -n "$CHECK_INTERVAL" ]]; then
    update_env "CHECK_INTERVAL" "$CHECK_INTERVAL"
    echo "✔ CHECK_INTERVAL = $CHECK_INTERVAL"
fi

if [[ -n "$MAX_RESTARTS" ]]; then
    update_env "MAX_RESTARTS" "$MAX_RESTARTS"
    echo "✔ MAX_RESTARTS = $MAX_RESTARTS"
fi

if [[ -n "$CPU_THRESHOLD" ]]; then
    sed -i "s|> [0-9]\+ # CPU_THRESHOLD|> ${CPU_THRESHOLD} # CPU_THRESHOLD|" "$RULES_FILE"
    echo "✔ Ngưỡng cảnh báo CPU = ${CPU_THRESHOLD}%"
fi

if [[ "$RESTART" == true ]]; then
    echo "-> Khởi động lại heal-nginx.service (Tầng 1)..."
    sudo systemctl restart heal-nginx.service
    echo "-> Nạp lại auto-healer (Tầng 2) để nhận MAX_RESTARTS mới..."
    (cd "$PROJECT_DIR" && docker compose up -d auto-healer > /dev/null)
    echo "-> Reload cấu hình Prometheus..."
    if curl -s -X POST http://localhost:9090/-/reload > /dev/null; then
        echo "✔ Prometheus đã reload"
    else
        echo "⚠ Không reload được Prometheus (kiểm tra container prometheus đang chạy chưa)"
    fi
fi
