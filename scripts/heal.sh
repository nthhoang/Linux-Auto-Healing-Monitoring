#!/usr/bin/env bash
# heal.sh - Auto-healing daemon cho Nginx
# Theo dõi endpoint /health; sau N lần fail liên tiếp -> docker restart container
# và gửi thông báo Telegram cả khi phát hiện DOWN lẫn khi RECOVERED.
# Chạy dưới dạng systemd service (xem install.sh / GUIDE.md).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/heal.env"

# ---- Cấu hình mặc định (có thể override qua scripts/heal.env) ----
HEALTH_URL="${HEALTH_URL:-http://localhost:8080/health}"
CONTAINER_NAME="${CONTAINER_NAME:-nginx}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

fail_count=0
is_down=false

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

send_telegram() {
    local text="$1"
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "parse_mode=HTML" \
            --data-urlencode "text=${text}" > /dev/null
    fi
}

log "heal.sh khởi động. Theo dõi ${HEALTH_URL} mỗi ${CHECK_INTERVAL}s (ngưỡng: ${FAIL_THRESHOLD} lần fail)"

while true; do
    if curl -sf -o /dev/null --max-time 3 "$HEALTH_URL"; then
        if [[ "$is_down" == true ]]; then
            log "✅ ${CONTAINER_NAME} ĐÃ PHỤC HỒI"
            send_telegram "$(printf '✅ <b>RECOVERED</b>\nContainer: %s\nTime: %s' "$CONTAINER_NAME" "$(date '+%H:%M:%S')")"
            is_down=false
        fi
        fail_count=0
    else
        fail_count=$((fail_count + 1))
        log "⚠️  Health check fail (${fail_count}/${FAIL_THRESHOLD})"

        if [[ "$fail_count" -ge "$FAIL_THRESHOLD" && "$is_down" == false ]]; then
            is_down=true
            log "🚨 ${CONTAINER_NAME} DOWN. Đang restart container..."
            send_telegram "$(printf '🚨 <b>DOWN DETECTED</b>\nContainer: %s\nAction: restarting...' "$CONTAINER_NAME")"
            docker restart "$CONTAINER_NAME" > /dev/null 2>&1
            fail_count=0
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
