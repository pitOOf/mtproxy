#!/bin/bash
#
# Автоустановка веб-панели mtproxy на Ubuntu (22.04/24.04).
# Полный сервер (прокси + панель + nginx): sudo bash install-full-server.sh
# Только панель: sudo bash install-web-panel.sh
# Без вопросов (все в переменных):
#   sudo MTPROTO_WEB_USER=admin MTPROTO_WEB_PASSWORD='пароль' \
#     MTPROTO_INSTALL_SCRIPT=/root/MTProtoProxyInstall.sh \
#     MTPROTO_PUBLIC_IP=1.2.3.4 MTPROTO_WEB_PORT=8080 \
#     bash install-web-panel.sh --yes
#
# Опционально (если есть /opt/mtprotoproxy/config.py):
#   MTPRO_STATS_PRINT_PERIOD=120  MTPRO_CLIENT_IPS_LEN=200
#
set -euo pipefail

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
RST='\033[0m'

die() { echo -e "${RED}Ошибка:${RST} $*" >&2; exit 1; }
info() { echo -e "${GRN}==>${RST} $*"; }
warn() { echo -e "${YLW}Внимание:${RST} $*"; }

mtproto_ensure_panel_journal_options() {
	local cfg="${1:-/opt/mtprotoproxy/config.py}"
	[[ -f "$cfg" ]] || return 0
	local period="${MTPRO_STATS_PRINT_PERIOD:-120}"
	local ips_len="${MTPRO_CLIENT_IPS_LEN:-200}"
	if ! [[ "$period" =~ ^[0-9]+$ ]] || [[ "$period" -lt 10 ]]; then
		echo "install-web-panel: неверный MTPRO_STATS_PRINT_PERIOD=${period}, использую 120" >&2
		period=120
	fi
	if ! [[ "$ips_len" =~ ^[0-9]+$ ]]; then
		echo "install-web-panel: неверный MTPRO_CLIENT_IPS_LEN=${ips_len}, использую 200" >&2
		ips_len=200
	fi
	local changed
	changed="$(
		_MTP_CFG="$cfg" _MTP_P="$period" _MTP_I="$ips_len" python3 <<'PY'
import os
import re

path = os.environ["_MTP_CFG"]
period = int(os.environ["_MTP_P"])
ips_len = int(os.environ["_MTP_I"])

text = open(path, encoding="utf-8").read()
changed = False
add: list[str] = []

if not re.search(r"^STATS_PRINT_PERIOD\s*=", text, re.M):
    add.append(f"STATS_PRINT_PERIOD = {period}")
    changed = True
if not re.search(r"^CLIENT_IPS_LEN\s*=", text, re.M):
    add.append(f"CLIENT_IPS_LEN = {ips_len}")
    changed = True

if changed:
    with open(path, "a", encoding="utf-8") as f:
        if text and not text.endswith("\n"):
            f.write("\n")
        f.write("\n# mtproxy: журнал для панели (TCP / New IPs)\n")
        for line in add:
            f.write(line + "\n")

print("1" if changed else "0")
PY
	)" || return 0
	changed="${changed//$'\r'/}"
	changed="${changed//$'\n'/}"
	if [[ "$changed" == "1" ]] && command -v systemctl >/dev/null 2>&1; then
		if systemctl is-active --quiet mtprotoproxy 2>/dev/null || systemctl is-enabled --quiet mtprotoproxy 2>/dev/null; then
			systemctl restart mtprotoproxy.service 2>/dev/null || true
		fi
	fi
}

if [[ "${EUID:-}" -ne 0 ]]; then
	die "Запустите от root: sudo bash $0"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_WEB="${SCRIPT_DIR}/web"
INSTALL_ROOT="/opt/mtproto-web"
ENV_FILE="/etc/mtproto-web.env"
UNIT_FILE="/etc/systemd/system/mtproto-web.service"
VENV_PY="${INSTALL_ROOT}/venv/bin/python3"
VENV_PIP="${INSTALL_ROOT}/venv/bin/pip"

NONINTERACTIVE=false
for a in "$@"; do
	[[ "$a" == "-y" || "$a" == "--yes" ]] && NONINTERACTIVE=true
done

[[ -f "${SRC_WEB}/app.py" ]] || die "Не найден ${SRC_WEB}/app.py — скрипт должен лежать рядом с папкой web/"

prompt() {
	local def="$2"
	local v
	if $NONINTERACTIVE; then
		echo "${!1:-$def}"
		return
	fi
	read -r -p "$3 [${def}]: " v
	echo "${v:-$def}"
}

prompt_secret() {
	local v
	if $NONINTERACTIVE; then
		[[ -n "${MTPROTO_WEB_PASSWORD:-}" ]] || die "Задайте MTPROTO_WEB_PASSWORD для режима --yes"
		echo "$MTPROTO_WEB_PASSWORD"
		return
	fi
	read -r -s -p "$1: " v
	echo
	[[ -n "$v" ]] || die "Пароль не может быть пустым"
	echo "$v"
}

info "Обновление списка пакетов…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
info "Установка Python и venv…"
apt-get install -y -qq python3 python3-pip python3-venv curl ca-certificates

if $NONINTERACTIVE; then
	WEB_USER="${MTPROTO_WEB_USER:-admin}"
	WEB_PASS="${MTPROTO_WEB_PASSWORD:?укажите MTPROTO_WEB_PASSWORD}"
	INSTALL_SCRIPT="${MTPROTO_INSTALL_SCRIPT:-/root/MTProtoProxyInstall.sh}"
	WEB_PORT="${MTPROTO_WEB_PORT:-8080}"
	PUBLIC_IP="${MTPROTO_PUBLIC_IP:-}"
	HTTPS_ONLY="${MTPROTO_SESSION_HTTPS_ONLY:-0}"
else
	WEB_USER="$(prompt WEB_USER admin "Логин для панели")"
	WEB_PASS="$(prompt_secret "Пароль для панели")"
	WEB_PASS2="$(prompt_secret "Повторите пароль")"
	[[ "$WEB_PASS" == "$WEB_PASS2" ]] || die "Пароли не совпадают"
	INSTALL_SCRIPT="$(prompt MTPROTO_INSTALL_SCRIPT /root/MTProtoProxyInstall.sh "Путь к MTProtoProxyInstall.sh")"
	WEB_PORT="$(prompt MTPROTO_WEB_PORT 8080 "Порт панели (только localhost, снаружи — через nginx)")"
	PUBLIC_IP="$(prompt MTPROTO_PUBLIC_IP "" "Публичный IP для ссылок tg:// (пусто = определить через ipify)")"
	read -r -p "Панель за HTTPS (nginx)? Включить Secure cookie [y/N]: " https_ans
	[[ "${https_ans,,}" == "y" ]] && HTTPS_ONLY=1 || HTTPS_ONLY=0
fi

if [[ -z "${PUBLIC_IP}" ]]; then
	PUBLIC_IP="$(curl -fsS https://api.ipify.org 2>/dev/null || true)"
	[[ -n "${PUBLIC_IP}" ]] || PUBLIC_IP="YOUR_IP"
fi

SESSION_SECRET="${MTPROTO_WEB_SESSION_SECRET:-}"
if [[ -z "${SESSION_SECRET}" ]]; then
	SESSION_SECRET="$(openssl rand -hex 32)"
fi

[[ -f "${INSTALL_SCRIPT}" ]] || warn "Файл ${INSTALL_SCRIPT} не найден. Укажите верный путь в ${ENV_FILE} после установки."

if [[ -f /opt/mtprotoproxy/config.py ]]; then
	info "Проверка config.py прокси: STATS_PRINT_PERIOD и CLIENT_IPS_LEN для панели"
	mtproto_ensure_panel_journal_options /opt/mtprotoproxy/config.py
fi

info "Копирование файлов в ${INSTALL_ROOT}…"
mkdir -p "${INSTALL_ROOT}"
cp -a "${SRC_WEB}/." "${INSTALL_ROOT}/"

info "Виртуальное окружение Python…"
python3 -m venv "${INSTALL_ROOT}/venv"
"${VENV_PIP}" install -q --upgrade pip
"${VENV_PIP}" install -q -r "${INSTALL_ROOT}/requirements.txt"

info "Запись ${ENV_FILE}…"
umask 077
# systemd EnvironmentFile: значения в кавычках, экранирование " и \
python3 - "${ENV_FILE}" "${WEB_USER}" "${WEB_PASS}" "${SESSION_SECRET}" "${INSTALL_SCRIPT}" "${PUBLIC_IP}" "${HTTPS_ONLY}" <<'PY'
import pathlib
import sys

def q(s: str) -> str:
    t = s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "$$")
    return '"' + t + '"'

path, user, password, sess, script, pub_ip, https_only = sys.argv[1:8]
text = "\n".join(
    [
        "# mtproto-web panel: chmod 600; after edits: systemctl restart mtproto-web",
        f"MTPROTO_WEB_USER={q(user)}",
        f"MTPROTO_WEB_PASSWORD={q(password)}",
        f"MTPROTO_WEB_SESSION_SECRET={q(sess)}",
        f"MTPROTO_INSTALL_SCRIPT={q(script)}",
        "MTPROTO_CONFIG=/opt/mtprotoproxy/config.py",
        f"MTPROTO_PUBLIC_IP={q(pub_ip)}",
        f"MTPROTO_SESSION_HTTPS_ONLY={q(https_only)}",
        "",
    ]
)
p = pathlib.Path(path)
p.write_text(text, encoding="utf-8")
p.chmod(0o600)
PY

info "Unit systemd ${UNIT_FILE}…"
cat >"${UNIT_FILE}" <<EOF
[Unit]
Description=mtproxy web panel (FastAPI)
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_ROOT}
EnvironmentFile=${ENV_FILE}
Environment=PYTHONUNBUFFERED=1
ExecStart=${VENV_PY} -m uvicorn app:app --host 127.0.0.1 --port ${WEB_PORT}
Restart=on-failure
RestartSec=5

# Панель вызывает bash-скрипт установки и journalctl; нужен root.
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mtproto-web.service
systemctl restart mtproto-web.service

sleep 1
if systemctl is-active --quiet mtproto-web.service; then
	info "Сервис mtproto-web запущен."
else
	warn "Сервис не в состоянии active. Смотрите: journalctl -u mtproto-web -e"
fi

SNIP="${INSTALL_ROOT}/nginx-example.conf"
cat >"${SNIP}" <<'NGX'
# Пример для nginx: HTTPS и прокси на панель
# sudo apt install nginx certbot python3-certbot-nginx
# поменяйте server_name и путь к ssl_certificate при необходимости
#
# server {
#   listen 443 ssl http2;
#   server_name panel.example.com;
#   ssl_certificate     /etc/letsencrypt/live/panel.example.com/fullchain.pem;
#   ssl_certificate_key /etc/letsencrypt/live/panel.example.com/privkey.pem;
#   location / {
#     proxy_pass http://127.0.0.1:8080;
#     proxy_http_version 1.1;
#     proxy_set_header Host $host;
#     proxy_set_header X-Real-IP $remote_addr;
#     proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
#     proxy_set_header X-Forwarded-Proto $scheme;
#   }
# }
NGX

echo
echo -e "${GRN}Готово.${RST}"
echo "  Панель слушает:  http://127.0.0.1:${WEB_PORT}"
echo "  Логин:           ${WEB_USER}"
echo "  Настройки:       ${ENV_FILE}"
echo "  Пример nginx:    ${SNIP}"
echo
echo "  Команды:  systemctl status mtproto-web | journalctl -u mtproto-web -f"
echo "  После смены пароля или IP: systemctl restart mtproto-web"
echo
if [[ "${HTTPS_ONLY}" == "1" ]]; then
	warn "Включён MTPROTO_SESSION_HTTPS_ONLY=1 — открывайте панель только по HTTPS, иначе cookie не установится."
fi
