#!/usr/bin/env bash
# test_scenario.sh - Demo tự động: dừng Nginx để giả lập sự cố, quan sát
# detect -> alert -> heal -> recover.

set -uo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-nginx}"
HEALTH_URL="${HEALTH_URL:-http://localhost:8080/health}"

echo "===================================================="
echo " DEMO: Auto-Healing Test Scenario"
echo "===================================================="

if command -v systemctl &> /dev/null && ! systemctl is-active --quiet heal-nginx.service 2>/dev/null; then
    echo
    echo "⚠️  CẢNH BÁO: heal-nginx.service chưa chạy — container sẽ KHÔNG tự phục hồi."
    echo "   Chạy: sudo systemctl start heal-nginx.service"
fi

echo
echo "[1/5] Trạng thái ban đầu:"
curl -s -o /dev/null -w "  -> ${HEALTH_URL} => HTTP %{http_code}\n" "$HEALTH_URL"
docker ps --filter "name=${CONTAINER_NAME}" --format "  -> Container: {{.Names}} ({{.Status}})"

echo
echo "[2/5] Đang dừng container '${CONTAINER_NAME}' để giả lập sự cố..."
docker stop "$CONTAINER_NAME" > /dev/null
echo "  -> Đã dừng lúc $(date '+%H:%M:%S')"

echo
echo "[3/5] Theo dõi heal.sh phát hiện & tự phục hồi (tối đa 60s)..."
recovered=false
for i in $(seq 1 60); do
    if curl -sf -o /dev/null --max-time 2 "$HEALTH_URL"; then
        echo "  ✅ Đã phục hồi sau ${i}s! Container đang chạy trở lại."
        recovered=true
        break
    fi
    printf "."
    sleep 1
done
echo
if [[ "$recovered" == false ]]; then
    echo "  ⚠️  Sau 60s vẫn chưa phục hồi. Kiểm tra: sudo systemctl status heal-nginx.service"
fi

echo
echo "[4/5] Kiểm tra Prometheus target 'nginx':"
curl -s "http://localhost:9090/api/v1/query?query=nginx_up" | grep -o '"value":\[[^]]*\]' || true

echo
echo "[5/5] Trạng thái cuối cùng:"
curl -s -o /dev/null -w "  -> ${HEALTH_URL} => HTTP %{http_code}\n" "$HEALTH_URL"
docker ps --filter "name=${CONTAINER_NAME}" --format "  -> Container: {{.Names}} ({{.Status}})"

echo
echo "===================================================="
echo " Mở Grafana (localhost:3000) và Telegram để xem"
echo " biểu đồ downtime + thông báo DOWN/RECOVERED."
echo "===================================================="
