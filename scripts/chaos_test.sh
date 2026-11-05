#!/usr/bin/env bash
# chaos_test.sh - CÔNG CỤ DUY NHẤT để kiểm tra hệ thống và tạo sự cố có kiểm soát.
# (Đã gộp test_scenario.sh cũ vào --kill-process.)
#
# Mỗi chế độ ứng với 1 "hồi" của buổi demo (xem README.md):
#   --preflight        Hồi 0  Kiểm tra mọi thứ khỏe trước khi demo
#   --kill-process     Hồi 1  Container chết -> Tầng 1 (heal.sh) restart nhanh
#   --stress-cpu [s]   Hồi 2  Quá tải CPU -> cảnh báo, KHÔNG restart
#   --corrupt-config   Hồi 3  Sai cấu hình -> Tầng 2 (auto-healer) RCA + rollback
#   --corrupt-config --manual
#                      Hồi 4  Tắt Auto-Heal trên Telegram rồi chạy: người xử lý bằng nút Rollback
#   --test-chatops     Kiểm tra bảng nút ChatOps

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

CONTAINER_NAME="${CONTAINER_NAME:-nginx}"
HEALTH_URL="${HEALTH_URL:-http://localhost:8080/health}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
CONF_FILE="nginx/nginx.conf"
BAK_FILE="nginx/nginx.conf.bak"

if [[ -f .env ]]; then set -a; source .env; set +a; fi

banner() { echo; echo "===================================================="; echo " $1"; echo "===================================================="; }
look()   { echo "   👀 NHÌN: $1"; }
is_healthy() { curl -sf -o /dev/null --max-time 2 "$HEALTH_URL"; }

# Chờ /health = 200, tối đa $1 giây. In dấu chấm; trả về 0 nếu phục hồi, đặt RECOVERED_AFTER.
RECOVERED_AFTER=0
wait_healthy() {
    local max="$1" start=$SECONDS
    while (( SECONDS - start < max )); do
        if is_healthy; then RECOVERED_AFTER=$((SECONDS - start)); echo; return 0; fi
        printf "."; sleep 1
    done
    echo; return 1
}

prom_value() {   # $1 = PromQL -> in giá trị (rỗng nếu lỗi)
    curl -s --max-time 3 --get --data-urlencode "query=$1" "${PROM_URL}/api/v1/query" \
        | grep -o '"value":\[[^]]*\]' | head -1 | sed -E 's/.*,"([^"]*)"\]/\1/'
}

# Chờ Prometheus thấy nginx_up == 1, tối đa $1 giây.
wait_nginx_up_metric() {
    local max="$1" start=$SECONDS
    while (( SECONDS - start < max )); do
        [[ "$(prom_value nginx_up)" == "1" ]] && { echo "   ✔ Prometheus thấy nginx_up = 1 sau $((SECONDS - start))s (chu kỳ scrape 10s)"; return 0; }
        sleep 2
    done
    echo "   ⚠ Sau ${max}s Prometheus chưa thấy nginx_up = 1"; return 1
}

telegram_ping() {
    [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 1
    curl -s --max-time 8 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$1" | grep -q '"ok":true'
}

# ---------------------------------------------------------------- HỒI 0
preflight() {
    banner "HỒI 0 - PREFLIGHT: kiểm tra trước khi demo"
    local fail=0
    chk() { if eval "$2" > /dev/null 2>&1; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
    warn() { if eval "$2" > /dev/null 2>&1; then echo "  ✅ $1"; else echo "  ⚠️  $1"; fi; }

    local total running
    total=$(docker compose config --services 2>/dev/null | wc -l)
    running=$(docker compose ps --status running --format '{{.Name}}' 2>/dev/null | wc -l)
    echo "  -> Container đang chạy: ${running}/${total}"
    chk "Tất cả container đều running" "[[ $running -eq $total && $total -gt 0 ]]"
    chk "Nginx /health = 200" "is_healthy"
    chk "Prometheus: mọi target UP" "! curl -s ${PROM_URL}/api/v1/targets | grep -q '\"health\":\"down\"' && curl -s ${PROM_URL}/api/v1/targets | grep -q '\"health\":\"up\"'"
    chk "Không có cảnh báo nào đang firing" "! curl -s ${PROM_URL}/api/v1/alerts | grep -q '\"state\":\"firing\"'"
    chk "Tầng 1: heal-nginx.service đang active" "systemctl is-active --quiet heal-nginx.service"
    chk "Tầng 2: auto-healer phản hồi" "curl -sf http://localhost:5001/health"
    chk "Tầng 2: Auto-Heal đang BẬT, Circuit Breaker đóng" "curl -s http://localhost:5001/status | grep -q '\"auto_heal_enabled\": true' && ! curl -s http://localhost:5001/status | grep -q '\"nginx\": true'"
    chk "Loki sẵn sàng" "curl -sf http://localhost:3100/ready"
    chk "Grafana sẵn sàng" "curl -s http://localhost:3000/api/health | grep -q ok"
    chk "Image alpine đã có sẵn (cho Hồi 2)" "docker image inspect alpine"
    warn "nginx.conf trùng nginx.conf.bak (bản rollback hợp lệ)" "cmp -s $CONF_FILE $BAK_FILE"
    if telegram_ping "✅ [PREFLIGHT] Bot Telegram hoạt động - sẵn sàng demo"; then
        echo "  ✅ Telegram: đã gửi tin thử (kiểm tra điện thoại)"
    else
        echo "  ❌ Telegram: không gửi được (kiểm tra token/chat id/mạng)"; fail=1
    fi
    echo
    if [[ $fail -eq 0 ]]; then echo " ✅ SẴN SÀNG DEMO"; else echo " ❌ Có mục chưa đạt - xử lý trước khi demo (xem docker compose ps / logs)"; return 1; fi
}

# ---------------------------------------------------------------- HỒI 1
kill_process() {
    banner "HỒI 1 - CONTAINER CHẾT (docker stop) -> Tầng 1 heal.sh"
    is_healthy || { echo "❌ Nginx đang không khỏe sẵn. Chạy --preflight trước."; return 1; }
    echo "[1/4] Baseline: /health = 200"
    echo "[2/4] Dừng container '$CONTAINER_NAME' lúc $(date '+%H:%M:%S')..."
    docker stop "$CONTAINER_NAME" > /dev/null
    look "Dashboard: Nginx Status UP -> DOWN | Telegram: [WATCHDOG] DOWN DETECTED"
    echo "[3/4] Chờ heal.sh phát hiện và restart (tối đa 60s)..."
    if wait_healthy 60; then
        echo "   ✅ Phục hồi sau ${RECOVERED_AFTER}s (không cần người can thiệp)"
        look "Telegram: [WATCHDOG] RECOVERED"
    else
        echo "   ⚠ Sau 60s chưa phục hồi: sudo systemctl status heal-nginx.service"; return 1
    fi
    echo "[4/4] Xác nhận trên Prometheus..."
    wait_nginx_up_metric 25
    docker ps --filter "name=${CONTAINER_NAME}" --format "   -> {{.Names}}: {{.Status}}"
}

# ---------------------------------------------------------------- HỒI 2
cpu_cleanup() { docker rm -f $(docker ps -aq --filter "name=cpu-burner") > /dev/null 2>&1 || true; }
stress_cpu() {
    local duration="${1:-110}" cores
    cores=$(nproc 2>/dev/null || echo 2)
    banner "HỒI 2 - QUÁ TẢI CPU (${cores} lõi x ${duration}s) -> cảnh báo, KHÔNG restart"
    docker image inspect alpine > /dev/null 2>&1 || docker pull -q alpine > /dev/null
    trap cpu_cleanup EXIT INT TERM
    for i in $(seq 1 "$cores"); do
        docker run -d --rm --name "cpu-burner-$i" alpine sh -c 'while :; do :; done' > /dev/null
    done
    echo "✔ Đã chạy ${cores} tiến trình ngốn CPU lúc $(date '+%H:%M:%S')"
    look "Dashboard: gauge CPU lên đỏ | Prometheus /alerts: HighCPUUsage Pending -> Firing (cần >85% trong 1 phút)"
    look "Telegram: [ALERT] FIRING HighCPUUsage, rồi [AUTO-HEALER] CHỈ KHUYẾN NGHỊ (không restart)"
    local start=$SECONDS
    while (( SECONDS - start < duration )); do
        sleep 10
        local cpu; cpu=$(prom_value '100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)')
        printf "   t=%3ds  CPU ≈ %.0f%%\n" $((SECONDS - start)) "${cpu:-0}"
    done
    cpu_cleanup; trap - EXIT INT TERM
    echo "✔ Đã giải phóng CPU. Tin [ALERT] RESOLVED sẽ đến sau khoảng 1-2 phút."
}

# ---------------------------------------------------------------- HỒI 3 & 4
restore_config() {
    if ! cmp -s "$CONF_FILE" "$BAK_FILE"; then
        cp "$BAK_FILE" "$CONF_FILE"     # cp ghi đè tại chỗ -> bind mount vẫn đúng file
        docker restart "$CONTAINER_NAME" > /dev/null 2>&1 || true
        echo "   ↩️  (an toàn) Đã trả nginx.conf về bản sao lưu"
    fi
}
corrupt_config() {
    local manual="${1:-}" max=75
    [[ "$manual" == "--manual" ]] && max=180
    if [[ "$manual" == "--manual" ]]; then
        banner "HỒI 4 - SAI CẤU HÌNH khi Auto-Heal ĐÃ TẮT -> con người xử lý bằng ChatOps"
        echo " (Hãy chắc chắn đã bấm nút [Tắt Auto-Heal] trên Telegram trước khi chạy)"
    else
        banner "HỒI 3 - SAI CẤU HÌNH nginx.conf -> Tầng 2 auto-healer: RCA + ROLLBACK"
    fi
    is_healthy || { echo "❌ Nginx đang không khỏe sẵn. Chạy --preflight trước."; return 1; }
    cp "$CONF_FILE" "$BAK_FILE"          # bản đang chạy tốt = last-known-good
    trap restore_config INT TERM
    echo "[1/3] Chèn dòng sai cú pháp vào $CONF_FILE và restart nginx..."
    echo "invalid_syntax_error_here;" >> "$CONF_FILE"
    docker restart "$CONTAINER_NAME" > /dev/null 2>&1 || true
    look "Grafana log panel / Loki: dòng [emerg] unknown directive (đây chính là thứ RCA đọc)"
    if [[ "$manual" == "--manual" ]]; then
        look "Telegram: [WATCHDOG] DOWN 1/3, 2/3, 3/3 rồi ⛔ CIRCUIT BREAKER OPEN (khoảng 60s)"
        look "Telegram: [AUTO-HEALER] báo 'đang bị tạm dừng' kèm nút -> bấm [↩️ Rollback Cấu hình]"
    else
        look "Telegram: [WATCHDOG] DOWN 1/3 -> [ALERT] FIRING -> [AUTO-HEALER] đã rollback -> [WATCHDOG] RECOVERED"
    fi
    echo "[2/3] Chờ phục hồi (tối đa ${max}s)..."
    if wait_healthy "$max"; then
        echo "   ✅ Nginx sống lại sau ${RECOVERED_AFTER}s"
        cmp -s "$CONF_FILE" "$BAK_FILE" && echo "   ✔ nginx.conf đã được trả về đúng bản sao lưu (rollback thành công)"
    else
        echo "   ⚠ Hết ${max}s chưa phục hồi - tự trả cấu hình về bản tốt."
    fi
    echo "[3/3] Dọn dẹp / xác nhận trạng thái cuối..."
    restore_config; trap - INT TERM
    wait_healthy 20 && echo "   ✔ /health = 200"
}

# ---------------------------------------------------------------- CHATOPS
test_chatops() {
    banner "KIỂM TRA CHATOPS 2 CHIỀU"
    if curl -sf http://localhost:5001/health | grep -q healthy; then
        echo "✔ auto-healer đang chạy (cổng 5001)."
        echo "   1. Trên Telegram nhắn /menu cho bot."
        echo "   2. Thử các nút: Health Check, Trạng thái Container, Xem 20 dòng Logs."
        echo "   3. Chỉ chat ID cấu hình trong .env mới được phép bấm nút."
    else
        echo "❌ Chưa kết nối được auto-healer: docker compose logs auto-healer"; return 1
    fi
}

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

[[ $# -eq 0 ]] && { usage; exit 0; }
case "$1" in
    --preflight)      preflight ;;
    --kill-process)   kill_process ;;
    --stress-cpu)     stress_cpu "${2:-110}" ;;
    --corrupt-config) corrupt_config "${2:-}" ;;
    --test-chatops)   test_chatops ;;
    -h|--help)        usage ;;
    *) echo "Tùy chọn không hợp lệ: $1"; usage; exit 1 ;;
esac
