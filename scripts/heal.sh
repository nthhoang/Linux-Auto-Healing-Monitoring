#!/usr/bin/env bash
# heal.sh - TẦNG 1 (Host Watchdog): người phản ứng nhanh, độc lập với Docker stack.
# Theo dõi /health mỗi CHECK_INTERVAL giây; sau FAIL_THRESHOLD lần fail liên tiếp
# -> docker restart (tối đa MAX_RESTARTS lần), quá số lần đó thì mở Circuit Breaker.
# Chỉ xử lý "container chết / không phản hồi". Việc chẩn đoán nguyên nhân (RCA),
# rollback cấu hình và ChatOps thuộc TẦNG 2 (container auto-healer).
# Cấu hình đọc từ file .env duy nhất ở thư mục gốc project (cùng file docker compose dùng).
# Chạy dưới dạng systemd service (do install.sh tạo: heal-nginx.service).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# ---- Cấu hình mặc định (override bằng file .env ở thư mục gốc) ----
HEALTH_URL="${HEALTH_URL:-http://localhost:8080/health}"
CONTAINER_NAME="${CONTAINER_NAME:-nginx}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
MAX_RESTARTS="${MAX_RESTARTS:-3}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

fail_count=0
restart_count=0
is_down=false
circuit_broken=false

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

log "heal.sh khởi động. Theo dõi ${HEALTH_URL} mỗi ${CHECK_INTERVAL}s (ngưỡng: ${FAIL_THRESHOLD} lần fail, max retries: ${MAX_RESTARTS})"

while true; do
    if curl -sf -o /dev/null --max-time 3 "$HEALTH_URL"; then
        if [[ "$is_down" == true ]]; then
            log "✅ ${CONTAINER_NAME} ĐÃ PHỤC HỒI THÀNH CÔNG"
            send_telegram "$(printf '✅ <b>[WATCHDOG] RECOVERED</b>\nContainer: <code>%s</code>\nTime: %s\nStatus: Endpoint healthy sau phục hồi.' "$CONTAINER_NAME" "$(date '+%Y-%m-%d %H:%M:%S')")"
            is_down=false
            restart_count=0
            circuit_broken=false
        fi
        fail_count=0
    else
        fail_count=$((fail_count + 1))
        log "⚠️  Health check fail (${fail_count}/${FAIL_THRESHOLD})"

        if [[ "$fail_count" -ge "$FAIL_THRESHOLD" ]]; then
            is_down=true

            if [[ "$circuit_broken" == true ]]; then
                # Circuit Breaker đang mở: ngắt mạch restart để chống loop vô tận và bảo vệ hệ thống
                log "⏸️  [Circuit Breaker OPEN] Tạm dừng auto-restart cho ${CONTAINER_NAME}. Đang chờ quản trị viên can thiệp..."
                fail_count=0
            else
                if [[ "$restart_count" -lt "$MAX_RESTARTS" ]]; then
                    restart_count=$((restart_count + 1))
                    log "🚨 ${CONTAINER_NAME} DOWN. Đang thử phục hồi (lần ${restart_count}/${MAX_RESTARTS})..."
                    send_telegram "$(printf '🚨 <b>[WATCHDOG] DOWN DETECTED</b>\nContainer: <code>%s</code>\nAction: Đang khởi động lại container...\nLần thử: <b>%d/%d</b>\nTime: %s' \
                        "$CONTAINER_NAME" "$restart_count" "$MAX_RESTARTS" "$(date '+%Y-%m-%d %H:%M:%S')")"

                    docker restart "$CONTAINER_NAME" > /dev/null 2>&1 || true
                    fail_count=0
                    # Tạm dừng ngắn để container có thời gian khởi tạo trước chu kỳ check tiếp theo
                    sleep 2
                else
                    circuit_broken=true
                    log "⛔ CRITICAL: ${CONTAINER_NAME} đã thất bại sau ${MAX_RESTARTS} lần restart liên tiếp! Kích hoạt Circuit Breaker."
                    send_telegram "$(printf '⛔ <b>[WATCHDOG] CRITICAL — CIRCUIT BREAKER OPEN</b>\nContainer: <code>%s</code>\nStatus: Thất bại sau <b>%d/%d</b> lần thử phục hồi.\nAction: Đã kích hoạt <b>Circuit Breaker</b> (dừng restart tự động để tránh crash loop).\n⚠️ <b>Yêu cầu:</b> Quản trị viên kiểm tra logs (<code>docker logs %s</code>).' \
                        "$CONTAINER_NAME" "$MAX_RESTARTS" "$MAX_RESTARTS" "$CONTAINER_NAME")"
                    fail_count=0
                fi
            fi
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
