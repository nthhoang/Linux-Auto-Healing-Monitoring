#!/usr/bin/env python3
"""
Auto-Healer & Interactive ChatOps Daemon
Dự án: Linux Auto-Healing & SRE Monitoring Architecture

VAI TRÒ TRONG KIẾN TRÚC (TẦNG 2 - bộ não chẩn đoán):
  - Tầng 1 (heal.sh trên host) lo việc "restart nhanh" khi container chết.
  - Tầng 2 (file này) chỉ vào cuộc khi cảnh báo NginxDown VẪN còn firing, tức là
    restart đơn thuần chưa đủ: chẩn đoán nguyên nhân, rollback cấu hình, ChatOps.
  - Alertmanager tự gửi tin [ALERT] FIRING/RESOLVED; file này chỉ gửi tin
    [AUTO-HEALER] mô tả HÀNH ĐỘNG đã làm, không lặp lại nội dung cảnh báo.

Chức năng:
1. Tiếp nhận Webhook từ Alertmanager khi có sự cố (Event-Driven Auto-Healing).
2. Phân tích nguyên nhân gốc rễ (Root Cause Analysis - RCA):
   - Nhận diện lỗi cấu hình cú pháp [emerg] -> Tự động Rollback file backup nginx.conf.bak.
   - Nhận diện container crash -> Tự động restart có Circuit Breaker chống loop.
3. ChatOps 2 chiều qua Telegram:
   - Cung cấp Inline Keyboard buttons điều khiển trực tiếp trên điện thoại.
   - Xác thực Chat ID bảo mật, chỉ admin được phép thực thi lệnh.
"""

import os
import sys
import html
import json
import time
import shutil
import logging
import threading
import urllib.request
import urllib.parse
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler

# Cấu hình logging
logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
logger = logging.getLogger("auto-healer")

# Biến môi trường
TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "").strip()
PORT = int(os.getenv("PORT", "5001"))
MAX_RESTARTS = int(os.getenv("MAX_RESTARTS", "3"))

NGINX_CONF_PATH = os.getenv("NGINX_CONF_PATH", "/app/nginx_config/nginx.conf")
NGINX_BAK_PATH = os.getenv("NGINX_BAK_PATH", "/app/nginx_config/nginx.conf.bak")
DOCKER_CONTAINER_NAME = os.getenv("CONTAINER_NAME", "nginx")

# Trạng thái toàn cục
state_lock = threading.Lock()
restart_counts = {}
circuit_broken = {}
auto_heal_enabled = True
last_notice = {}          # key -> timestamp lần gửi Telegram gần nhất (chống spam)

# Khởi tạo Docker client
docker_client = None
try:
    import docker
    docker_client = docker.from_env()
    logger.info("✔ Kết nối thành công tới Docker Engine Socket.")
except Exception as e:
    logger.warning(f"⚠ Chưa thể kết nối Docker SDK: {e}. Sẽ dùng fallback HTTP/CLI nếu có.")

# ====================================================================
# TELEGRAM HELPER FUNCTIONS
# ====================================================================

def send_telegram_api(method, payload):
    """Gửi request tới Telegram Bot API"""
    if not TELEGRAM_BOT_TOKEN:
        logger.warning(f"Chưa cấu hình TELEGRAM_BOT_TOKEN. Bỏ qua gửi {method}.")
        return None
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/{method}"
    headers = {"Content-Type": "application/json"}
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))
    except Exception as e:
        logger.error(f"Lỗi gọi Telegram API {method}: {e}")
        return None

def send_message(text, chat_id=None, reply_markup=None):
    cid = chat_id or TELEGRAM_CHAT_ID
    if not cid:
        return None
    payload = {
        "chat_id": cid,
        "text": text,
        "parse_mode": "HTML"
    }
    if reply_markup:
        payload["reply_markup"] = reply_markup
    return send_telegram_api("sendMessage", payload)

def edit_message_text(text, chat_id, message_id, reply_markup=None):
    payload = {
        "chat_id": chat_id,
        "message_id": message_id,
        "text": text,
        "parse_mode": "HTML"
    }
    if reply_markup:
        payload["reply_markup"] = reply_markup
    return send_telegram_api("editMessageText", payload)

def answer_callback(callback_query_id, text="", show_alert=False):
    payload = {
        "callback_query_id": callback_query_id,
        "text": text,
        "show_alert": show_alert
    }
    return send_telegram_api("answerCallbackQuery", payload)

def build_main_keyboard():
    """Tạo bảng nút bấm tương tác (Inline Keyboard) cho ChatOps"""
    heal_status_icon = "🟢" if auto_heal_enabled else "🔴"
    heal_status_text = "Tắt Auto-Heal" if auto_heal_enabled else "Bật Auto-Heal"
    return {
        "inline_keyboard": [
            [
                {"text": "🔄 Khởi động lại Nginx", "callback_data": "restart:nginx"},
                {"text": "📋 Xem 20 dòng Logs", "callback_data": "logs:nginx"}
            ],
            [
                {"text": "↩️ Rollback Cấu hình", "callback_data": "rollback:nginx"},
                {"text": "🩺 Health Check", "callback_data": "health:nginx"}
            ],
            [
                {"text": "📊 Trạng thái Container", "callback_data": "status:all"},
                {"text": f"{heal_status_icon} {heal_status_text}", "callback_data": "toggle:heal"}
            ]
        ]
    }

# ====================================================================
# DOCKER ACTIONS & ROOT CAUSE ANALYSIS (RCA)
# ====================================================================

def notice_due(key, cooldown):
    """True nếu đã quá 'cooldown' giây kể từ lần gửi thông báo cùng khoá."""
    now = time.time()
    if now - last_notice.get(key, 0) >= cooldown:
        last_notice[key] = now
        return True
    return False

def reset_incident(name):
    """Sự cố kết thúc: xoá bộ đếm restart, đóng Circuit Breaker, xoá khoá chống spam."""
    with state_lock:
        restart_counts[name] = 0
        circuit_broken[name] = False
    for k in [k for k in last_notice if k.startswith("NginxDown:")]:
        last_notice.pop(k, None)

def get_container(name):
    if not docker_client:
        return None
    try:
        return docker_client.containers.get(name)
    except Exception:
        return None

def do_restart_container(name):
    if not docker_client:
        return False, "Docker SDK không khả dụng"
    try:
        c = docker_client.containers.get(name)
        c.restart(timeout=10)
        return True, f"Container {name} đã khởi động lại thành công."
    except Exception as e:
        return False, str(e)

def do_get_logs(name, tail=20, since=None):
    if not docker_client:
        return "Docker SDK không khả dụng."
    try:
        c = docker_client.containers.get(name)
        kwargs = {"tail": tail, "timestamps": True}
        if since is not None:
            kwargs["since"] = since
        logs = c.logs(**kwargs).decode("utf-8", errors="replace")
        return logs or "(Không có log nào gần đây)"
    except Exception as e:
        return f"Lỗi lấy log: {e}"

def do_rollback_config():
    """Phục hồi file nginx.conf từ bản sao lưu nginx.conf.bak"""
    try:
        # Nếu đường dẫn container mount: /app/nginx_config
        # Hoặc đường dẫn local tương đối
        target = NGINX_CONF_PATH
        backup = NGINX_BAK_PATH
        if not os.path.exists(backup):
            # Thử tìm ở thư mục tương đối
            alt_bak = os.path.join(os.path.dirname(__file__), "..", "nginx", "nginx.conf.bak")
            alt_tgt = os.path.join(os.path.dirname(__file__), "..", "nginx", "nginx.conf")
            if os.path.exists(alt_bak):
                backup = alt_bak
                target = alt_tgt
            else:
                return False, f"Không tìm thấy file sao lưu '{backup}'."

        shutil.copyfile(backup, target)
        logger.info(f"✔ Đã rollback cấu hình từ {backup} sang {target}")
        # Khởi động lại container Nginx để nạp cấu hình mới
        do_restart_container(DOCKER_CONTAINER_NAME)
        return True, f"Đã khôi phục file cấu hình thành công từ {os.path.basename(backup)}."
    except Exception as e:
        return False, f"Lỗi khi rollback: {e}"

def check_nginx_health():
    """Kiểm tra endpoint /health"""
    urls_to_try = [
        "http://nginx:80/health",
        "http://localhost:8080/health",
        "http://127.0.0.1:8080/health"
    ]
    for url in urls_to_try:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "auto-healer"})
            with urllib.request.urlopen(req, timeout=3) as resp:
                if resp.status == 200:
                    return True, "200 OK (Endpoint hoạt động bình thường)"
        except Exception:
            continue
    return False, "Không thể kết nối tới /health (Dịch vụ đang dừng hoặc lỗi)"

def get_containers_status():
    """Tóm tắt trạng thái các container trong hệ thống"""
    if not docker_client:
        return "Docker client không sẵn sàng."
    try:
        containers = docker_client.containers.list(all=True)
        lines = []
        for c in containers:
            icon = "🟢" if c.status == "running" else "🔴"
            lines.append(f"{icon} <b>{c.name}</b>: {c.status}")
        return "\n".join(lines) if lines else "Không có container nào đang chạy."
    except Exception as e:
        return f"Lỗi lấy trạng thái: {e}"

def perform_rca_and_heal(container_name=DOCKER_CONTAINER_NAME):
    """
    Phân tích nguyên nhân gốc rễ (Root Cause Analysis - RCA) và tự phục hồi
    """
    global auto_heal_enabled
    with state_lock:
        if not auto_heal_enabled:
            return "PAUSED", "Auto-Healing đang bị tạm dừng bởi quản trị viên."

        if circuit_broken.get(container_name, False):
            return "CIRCUIT_BREAKER_ACTIVE", (
                f"⛔ <b>Circuit Breaker đang mở</b> cho {container_name}.\n"
                f"Đã thất bại sau {MAX_RESTARTS} lần restart liên tiếp. "
                f"Vui lòng can thiệp thủ công để kiểm tra nguyên nhân chuyên sâu."
            )

        # 1. Kiểm tra logs để chẩn đoán nguyên nhân
        # Chỉ đọc log 90 giây gần nhất để không nhầm với lỗi [emerg] của sự cố cũ
        logs = do_get_logs(container_name, tail=50, since=int(time.time()) - 90)
        is_syntax_error = (
            "[emerg]" in logs or
            "syntax error" in logs.lower() or
            "configuration file" in logs and "failed" in logs
        )

        # Trường hợp 1: Lỗi cú pháp cấu hình -> Tự động Rollback
        if is_syntax_error:
            logger.warning(f"RCA: Phát hiện lỗi cú pháp cấu hình trong {container_name}. Tiến hành Rollback...")
            success, msg = do_rollback_config()
            if success:
                restart_counts[container_name] = 0
                return "ROLLBACK_APPLIED", (
                    "⚠️ <b>Phân tích RCA:</b> Phát hiện lỗi cú pháp cấu hình (Syntax Error / [emerg]).\n"
                    "🛠️ <b>Hành động:</b> Đã tự động khôi phục cấu hình từ <code>nginx.conf.bak</code> và khởi động lại Nginx!"
                )
            else:
                return "ROLLBACK_FAILED", f"Phát hiện lỗi cú pháp nhưng rollback thất bại: {msg}"

        # Trường hợp 2: Lỗi crash thông thường -> Auto-restart có giới hạn
        cur_count = restart_counts.get(container_name, 0) + 1
        restart_counts[container_name] = cur_count

        if cur_count > MAX_RESTARTS:
            circuit_broken[container_name] = True
            logger.error(f"⛔ Kích hoạt Circuit Breaker cho {container_name} sau {MAX_RESTARTS} lần restart.")
            return "CIRCUIT_BREAKER_TRIPPED", (
                f"⛔ <b>CRITICAL:</b> {container_name} không thể phục hồi sau <b>{MAX_RESTARTS}</b> lần restart liên tiếp!\n"
                f"Đã ngắt mạch tự động (Circuit Breaker) để bảo vệ hệ thống khỏi crash loop."
            )

        logger.info(f"RCA: Tiến hành restart {container_name} (Lần {cur_count}/{MAX_RESTARTS})...")
        success, msg = do_restart_container(container_name)
        if success:
            return "RESTARTED", (
                f"🔄 <b>Phân tích RCA:</b> Container bị dừng / không phản hồi HTTP.\n"
                f"🛠️ <b>Hành động:</b> Đã khởi động lại container thành công (Lần thử: <b>{cur_count}/{MAX_RESTARTS}</b>)."
            )
        else:
            return "RESTART_FAILED", f"Khởi động lại thất bại: {msg}"

# ====================================================================
# WEBHOOK HANDLER (ALERTMANAGER)
# ====================================================================

def process_alertmanager_webhook(payload):
    """Xử lý cảnh báo từ Alertmanager đẩy sang"""
    status = payload.get("status", "")
    alerts = payload.get("alerts", [])
    logger.info(f"Nhận webhook Alertmanager: status={status}, số lượng alerts={len(alerts)}")

    for alert in alerts:
        alert_status = alert.get("status", status)
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})
        alert_name = labels.get("alertname", "UnknownAlert")
        summary = annotations.get("summary", "")
        description = annotations.get("description", "")
        now_str = time.strftime("%Y-%m-%d %H:%M:%S")

        if alert_status == "firing":
            if alert_name == "NginxDown":
                # Alertmanager nhắc lại mỗi ~30s khi sự cố còn kéo dài -> mỗi lần là 1 lượt xử lý
                action_type, action_detail = perform_rca_and_heal(DOCKER_CONTAINER_NAME)
                if action_type in ("PAUSED", "CIRCUIT_BREAKER_ACTIVE") and \
                        not notice_due(f"NginxDown:{action_type}", 3600):
                    logger.info(f"NginxDown vẫn firing ({action_type}) - đã báo rồi, bỏ qua để tránh spam.")
                    continue
                msg = (
                    f"🛠 <b>[AUTO-HEALER] XỬ LÝ SỰ CỐ NginxDown</b>\n"
                    f"━━━━━━━━━━━━━━━━━━\n"
                    f"{action_detail}\n\n"
                    f"• <b>Thời gian:</b> {now_str}\n"
                    f"👇 <i>Điều khiển trực tiếp bằng các nút bên dưới:</i>"
                )
                send_message(msg, reply_markup=build_main_keyboard())

            elif alert_name in ["HighCPUUsage", "HighMemoryUsage"]:
                # Chỉ khuyến nghị, không restart. Nhắc tối đa 1 lần / 10 phút.
                if not notice_due(alert_name, 600):
                    continue
                msg = (
                    f"🧠 <b>[AUTO-HEALER] {alert_name}: CHỈ KHUYẾN NGHỊ</b>\n"
                    f"━━━━━━━━━━━━━━━━━━\n"
                    f"Quá tải tài nguyên không giải quyết được bằng restart nên hệ thống "
                    f"<b>không tự restart</b> container.\n"
                    f"<i>Hãy kiểm tra tiến trình đang chiếm CPU/RAM (top, docker stats).</i>\n"
                    f"• <b>Thời gian:</b> {now_str}"
                )
                send_message(msg, reply_markup=build_main_keyboard())

            else:
                # Các cảnh báo khác đã có tin [ALERT] từ Alertmanager; ở đây chỉ ghi log
                logger.info(f"Cảnh báo {alert_name} (firing) - không có hành động tự động.")

        elif alert_status == "resolved":
            # Tin [ALERT] RESOLVED do Alertmanager gửi; ở đây chỉ reset trạng thái xử lý
            if alert_name == "NginxDown":
                reset_incident(DOCKER_CONTAINER_NAME)
            else:
                last_notice.pop(alert_name, None)
            logger.info(f"Cảnh báo {alert_name} đã resolved - reset trạng thái.")

class WebhookServer(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"healthy","service":"auto-healer"}')
        elif self.path == "/status":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            status_data = {
                "auto_heal_enabled": auto_heal_enabled,
                "restart_counts": restart_counts,
                "circuit_broken": circuit_broken
            }
            self.wfile.write(json.dumps(status_data).encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/webhook":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            try:
                payload = json.loads(body.decode("utf-8"))
                # Chạy xử lý webhook trong thread riêng để trả lời HTTP ngay lập tức
                threading.Thread(target=process_alertmanager_webhook, args=(payload,), daemon=True).start()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"status":"accepted"}')
            except Exception as e:
                logger.error(f"Lỗi parse webhook JSON: {e}")
                self.send_response(400)
                self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        # Ẩn bớt log truy cập HTTP thông thường để console gọn gàng
        return

# ====================================================================
# CHATOPS TELEGRAM POLLER (TƯƠNG TÁC 2 CHIỀU)
# ====================================================================

def run_telegram_polling():
    """Vòng lặp lắng nghe lệnh và tương tác từ Telegram Bot (Long Polling)"""
    global auto_heal_enabled

    if not TELEGRAM_BOT_TOKEN:
        logger.warning("TELEGRAM_BOT_TOKEN rỗng. ChatOps 2 chiều sẽ không hoạt động.")
        return

    logger.info("🤖 Bắt đầu lắng nghe Telegram ChatOps Poller...")
    offset = 0

    while True:
        try:
            url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/getUpdates?offset={offset}&timeout=20"
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read().decode("utf-8"))

            if not data.get("ok"):
                time.sleep(5)
                continue

            for update in data.get("result", []):
                offset = update["update_id"] + 1

                # 1. Xử lý tin nhắn văn bản / lệnh gõ
                if "message" in update:
                    msg = update["message"]
                    chat_id = str(msg.get("chat", {}).get("id", ""))
                    text = msg.get("text", "").strip()

                    # Kiểm tra bảo mật Chat ID
                    if TELEGRAM_CHAT_ID and chat_id != str(TELEGRAM_CHAT_ID):
                        send_message("⛔ <b>Từ chối truy cập:</b> Bạn không có quyền quản trị hệ thống này.", chat_id=chat_id)
                        continue

                    if text in ["/start", "/menu", "/help"]:
                        welcome_text = (
                            f"🤖 <b>HỆ THỐNG SRE CHATOPS & AUTO-HEALING</b>\n"
                            f"Xin chào Quản trị viên! Hệ thống đang giám sát và sẵn sàng nhận lệnh.\n"
                            f"Trạng thái Auto-Healing: <b>{'BẬT (Active)' if auto_heal_enabled else 'TẮT (Paused)'}</b>\n\n"
                            f"<i>Vui lòng bấm vào các nút điều khiển bên dưới để thao tác:</i>"
                        )
                        send_message(welcome_text, chat_id=chat_id, reply_markup=build_main_keyboard())

                    elif text == "/status":
                        status_info = get_containers_status()
                        send_message(f"📊 <b>TRẠNG THÁI HỆ THỐNG:</b>\n\n{status_info}", chat_id=chat_id)

                # 2. Xử lý sự kiện bấm nút Inline Keyboard (Callback Query)
                elif "callback_query" in update:
                    cq = update["callback_query"]
                    cq_id = cq["id"]
                    from_user = cq.get("from", {}).get("first_name", "Admin")
                    cb_data = cq.get("data", "")
                    message = cq.get("message", {})
                    chat_id = str(message.get("chat", {}).get("id", ""))
                    msg_id = message.get("message_id")

                    # Xác thực bảo mật người bấm nút
                    if TELEGRAM_CHAT_ID and chat_id != str(TELEGRAM_CHAT_ID):
                        answer_callback(cq_id, "⛔ Bạn không có quyền thực thi thao tác này!", show_alert=True)
                        continue

                    action_now = time.strftime("%H:%M:%S")

                    if cb_data == "restart:nginx":
                        answer_callback(cq_id, "Đang khởi động lại Nginx...")
                        success, detail = do_restart_container(DOCKER_CONTAINER_NAME)
                        if success:
                            reset_incident(DOCKER_CONTAINER_NAME)
                        icon = "✅" if success else "❌"
                        response_text = (
                            f"{icon} <b>[CHATOPS ACTION] RESTART NGINX</b>\n"
                            f"• Thực hiện bởi: <b>{from_user}</b> lúc {action_now}\n"
                            f"• Kết quả: {detail}"
                        )
                        send_message(response_text, chat_id=chat_id, reply_markup=build_main_keyboard())

                    elif cb_data == "logs:nginx":
                        answer_callback(cq_id, "Đang lấy logs...")
                        raw_logs = do_get_logs(DOCKER_CONTAINER_NAME, tail=15)
                        # Giới hạn độ dài để tránh vượt quá giới hạn Telegram
                        truncated = raw_logs[-3500:] if len(raw_logs) > 3500 else raw_logs
                        response_text = (
                            f"📋 <b>[CHATOPS LOGS] 15 DÒNG LOG GẦN NHẤT CỦA NGINX:</b>\n"
                            f"<code>{html.escape(truncated)}</code>"
                        )
                        send_message(response_text, chat_id=chat_id, reply_markup=build_main_keyboard())

                    elif cb_data == "rollback:nginx":
                        answer_callback(cq_id, "Đang thực hiện Rollback cấu hình...")
                        success, detail = do_rollback_config()
                        if success:
                            reset_incident(DOCKER_CONTAINER_NAME)
                        icon = "✅" if success else "❌"
                        response_text = (
                            f"{icon} <b>[CHATOPS ACTION] ROLLBACK CONFIGURATION</b>\n"
                            f"• Thực hiện bởi: <b>{from_user}</b> lúc {action_now}\n"
                            f"• Trạng thái: {detail}"
                        )
                        send_message(response_text, chat_id=chat_id, reply_markup=build_main_keyboard())

                    elif cb_data == "health:nginx":
                        answer_callback(cq_id, "Đang kiểm tra /health...")
                        is_ok, detail = check_nginx_health()
                        icon = "🟢" if is_ok else "🔴"
                        response_text = (
                            f"{icon} <b>[CHATOPS HEALTH CHECK]</b>\n"
                            f"• Endpoint: <code>/health</code>\n"
                            f"• Kết quả: <b>{detail}</b> lúc {action_now}"
                        )
                        send_message(response_text, chat_id=chat_id, reply_markup=build_main_keyboard())

                    elif cb_data == "status:all":
                        answer_callback(cq_id, "Đang kiểm tra tất cả container...")
                        status_info = get_containers_status()
                        response_text = (
                            f"📊 <b>[CHATOPS SYSTEM OVERVIEW]</b> lúc {action_now}:\n"
                            f"━━━━━━━━━━━━━━━━━━\n"
                            f"{status_info}"
                        )
                        send_message(response_text, chat_id=chat_id, reply_markup=build_main_keyboard())

                    elif cb_data == "toggle:heal":
                        with state_lock:
                            auto_heal_enabled = not auto_heal_enabled
                            current_state = auto_heal_enabled
                        for k in [k for k in last_notice if k.startswith("NginxDown:")]:
                            last_notice.pop(k, None)
                        state_str = "BẬT (Active)" if current_state else "TẠM DỪNG (Paused)"
                        answer_callback(cq_id, f"Auto-Healing hiện đã: {state_str}")
                        send_message(
                            f"⚙️ <b>[CHATOPS CONFIG]</b> Admin <b>{from_user}</b> đã chuyển trạng thái Auto-Healing thành: <b>{state_str}</b>.",
                            chat_id=chat_id,
                            reply_markup=build_main_keyboard()
                        )

        except urllib.error.URLError:
            # Lỗi mạng tạm thời, chờ một chút rồi thử lại
            time.sleep(5)
        except Exception as e:
            logger.error(f"Lỗi trong Telegram polling loop: {e}")
            time.sleep(3)

# ====================================================================
# MAIN ENTRYPOINT
# ====================================================================

def main():
    logger.info("=" * 60)
    logger.info("KHỞI ĐỘNG HỆ THỐNG SRE AUTO-HEALER & CHATOPS CONTROLLER")
    logger.info("=" * 60)
    logger.info(f"Cổng Webhook lắng nghe: {PORT}")
    logger.info(f"Target Container: {DOCKER_CONTAINER_NAME}")
    logger.info(f"Max Restarts (Circuit Breaker): {MAX_RESTARTS}")

    # Bắt đầu thread Polling Telegram
    polling_thread = threading.Thread(target=run_telegram_polling, daemon=True)
    polling_thread.start()

    # Bắt đầu HTTP Webhook Server
    server_address = ("", PORT)
    httpd = HTTPServer(server_address, WebhookServer)
    logger.info(f"✔ Webhook HTTP Server đang chạy tại http://0.0.0.0:{PORT}/webhook")

    # Gửi thông báo chào mừng khởi động hệ thống
    if TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID:
        send_message(
            "🚀 <b>Hệ thống SRE Auto-Healer & ChatOps đã khởi động thành công!</b>\n"
            "Đang kết nối Alertmanager và giám sát cụm dịch vụ.",
            reply_markup=build_main_keyboard()
        )

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        logger.info("Đang dừng dịch vụ...")
        httpd.server_close()

if __name__ == "__main__":
    main()
