#!/bin/bash
#
# Тихая установка MTProto-прокси из каталога bundled-mtprotoproxy/ (без git clone).
# Конфиг: config/mtprotoproxy-config.py в этом репозитории → /opt/mtprotoproxy/config.py
# Если файла нет — генерируется минимальный config из переменных окружения ниже.
#
# Переменные окружения (опционально):
#   MTPRO_PROXY_PORT=443
#   MTPRO_PROXY_TLS_DOMAIN=www.cloudflare.com
#   MTPRO_STATS_PRINT_PERIOD=120
#   MTPRO_CLIENT_IPS_LEN=200
#
# Запуск: sudo bash install-mtproto-proxy-headless.sh
# Чаще: sudo bash install-full-server.sh --proxy-no-secrets
#
set -euo pipefail

[[ "${EUID:-}" -eq 0 ]] || {
	echo "Нужен root: sudo bash $0" >&2
	exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="${SCRIPT_DIR}/bundled-mtprotoproxy"
REPO_CFG="${SCRIPT_DIR}/config/mtprotoproxy-config.py"

PORT="${MTPRO_PROXY_PORT:-443}"
TLS_DOMAIN="${MTPRO_PROXY_TLS_DOMAIN:-www.cloudflare.com}"
STATS_PERIOD="${MTPRO_STATS_PRINT_PERIOD:-120}"
IPS_LEN="${MTPRO_CLIENT_IPS_LEN:-200}"

if [[ ! -f "${BUNDLE}/mtprotoproxy.py" ]]; then
	echo "Ошибка: нет ${BUNDLE}/mtprotoproxy.py" >&2
	echo "  Склонируйте репозиторий с bundled-mtprotoproxy или выполните: bash scripts/update-mtprotoproxy-bundle.sh" >&2
	exit 1
fi

if [[ -d /opt/mtprotoproxy ]]; then
	echo "Ошибка: уже есть /opt/mtprotoproxy. Удалите каталог или не запускайте headless." >&2
	echo "  sudo systemctl stop mtprotoproxy 2>/dev/null; sudo rm -rf /opt/mtprotoproxy" >&2
	exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -gt 65535 ]]; then
	echo "Неверный MTPRO_PROXY_PORT" >&2
	exit 1
fi
if ! [[ "$STATS_PERIOD" =~ ^[0-9]+$ ]] || [[ "$STATS_PERIOD" -lt 10 ]]; then
	echo "Неверный MTPRO_STATS_PRINT_PERIOD" >&2
	exit 1
fi
if ! [[ "$IPS_LEN" =~ ^[0-9]+$ ]]; then
	echo "Неверный MTPRO_CLIENT_IPS_LEN" >&2
	exit 1
fi

. /etc/os-release 2>/dev/null || true
if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
	echo "Поддерживаются Ubuntu и Debian." >&2
	exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-pip sed curl ca-certificates

timedatectl set-ntp true 2>/dev/null || true

if python3 -m pip install -q cryptography uvloop --break-system-packages 2>/dev/null; then
	:
elif ! python3 -m pip install -q cryptography uvloop; then
	pip3 install -q cryptography uvloop
fi

mkdir -p /opt/mtprotoproxy
umask 022
cp -a "${BUNDLE}/." /opt/mtprotoproxy/
# Удаляем служебные файлы репозитория, если попали в копирование
rm -f /opt/mtprotoproxy/UPSTREAM.md

cd /opt/mtprotoproxy

if [[ -f "$REPO_CFG" ]]; then
	cp -a "$REPO_CFG" /opt/mtprotoproxy/config.py
	chmod 0644 /opt/mtprotoproxy/config.py
	info_msg="Конфиг из репозитория: config/mtprotoproxy-config.py"
else
	cat >config.py <<EOF
PORT = ${PORT}
USERS = {}
USER_MAX_TCP_CONNS = {}
TLS_DOMAIN = "${TLS_DOMAIN}"
MODES = { "classic": False, "secure": False, "tls": True }
STATS_PRINT_PERIOD = ${STATS_PERIOD}
CLIENT_IPS_LEN = ${IPS_LEN}
EOF
	chmod 0644 config.py
	info_msg="Сгенерирован минимальный config.py (добавьте в репозиторий config/mtprotoproxy-config.py)"
fi

: >limits_bash.txt
echo '{}' >limits_date.json
echo '{}' >limits_quota.json

cat >/etc/systemd/system/mtprotoproxy.service <<EOF
[Unit]
Description=mtproxy (MTProto proxy)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/mtprotoproxy/mtprotoproxy.py
StartLimitBurst=0
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mtprotoproxy.service
systemctl restart mtprotoproxy.service

PORT_FW="${PORT}"
if command -v python3 >/dev/null 2>&1; then
	PORT_FW="$(python3 <<'PY'
ns = {}
with open("/opt/mtprotoproxy/config.py", encoding="utf-8") as f:
    exec(f.read(), ns)
print(int(ns.get("PORT", 443)))
PY
)" || PORT_FW="${PORT}"
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
	ufw allow "${PORT_FW}/tcp" comment 'mtprotoproxy' || true
fi

echo "Готово: mtprotoproxy из bundled-mtprotoproxy, порт из config.py. ${info_msg}"
