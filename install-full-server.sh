#!/bin/bash
#
# Установка с нуля на новый Ubuntu-сервер:
#   1) MTProto-прокси (официальный MTProtoProxyInstall.sh, интерактивный мастер)
#   2) Веб-панель на 127.0.0.1:внутренний_порт
#   3) nginx + самоподписанный HTTPS на :8443 (по умолчанию)
#   4) Случайный путь вида https://IP:8443/aB3dEfGhIjKlMnOpQrSt/ + логин и пароль в /root/mtproto-panel-access.txt
#
# Скопируйте весь репозиторий (например mtproxy) на сервер и выполните:
#   sudo bash install-full-server.sh
#
# Без мастера секретов прокси (USERS={}; секреты только через панель):
#   sudo bash install-full-server.sh --proxy-no-secrets
#   sudo bash install-full-server.sh --proxy-no-secrets --yes    # полностью автоматически
#
# Уже есть прокси, только панель + внешний доступ:
#   sudo bash install-full-server.sh --skip-proxy
#
# Полностью без вопросов (прокси уже установлен):
#   sudo bash install-full-server.sh --skip-proxy --yes
#
# Переменные (опционально):
#   MTPROTO_INSTALLER_URL  MTPRO_INSTALL_SCRIPT  MTPRO_INTERNAL_PANEL_PORT (по умолчанию 18080)
#   MTPRO_NGINX_SSL_PORT   (по умолчанию 8443)
#   MTPROTO_PUBLIC_IP      (иначе ipify)
#   MTPRO_PROXY_PORT       порт прокси при --proxy-no-secrets (по умолчанию 443)
#   MTPRO_PROXY_TLS_DOMAIN маска TLS при --proxy-no-secrets
#   MTPRO_STATS_PRINT_PERIOD  интервал «Stats for …» в journal (сек., по умолчанию 120)
#   MTPRO_CLIENT_IPS_LEN      учёт IP / New IPs (по умолчанию 200; 0 = выкл.)
#   --yes: MTPROTO_WEB_USER MTPROTO_WEB_PASSWORD (иначе генерируются)
#
# Интерактивный MTProtoProxyInstall.sh лучше запускать из обычного SSH с TTY (иначе ввод при нескольких секретах может зависнуть).
#
set -euo pipefail

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
CYN='\033[0;36m'
BOLD='\033[1m'
RST='\033[0m'

die() { echo -e "${RED}Ошибка:${RST} $*" >&2; exit 1; }
info() { echo -e "${GRN}==>${RST} $*"; }
warn() { echo -e "${YLW}Внимание:${RST} $*"; }
step() { echo -e "${CYN}>>>${RST} $*"; }

[[ "${EUID:-}" -ne 0 ]] && die "Запустите от root: sudo bash $0"

# Дописывает в config.py STATS_PRINT_PERIOD и CLIENT_IPS_LEN, если их ещё нет (для панели / journal).
mtproto_ensure_panel_journal_options() {
	local cfg="${1:-/opt/mtprotoproxy/config.py}"
	[[ -f "$cfg" ]] || return 0
	local period="${MTPRO_STATS_PRINT_PERIOD:-120}"
	local ips_len="${MTPRO_CLIENT_IPS_LEN:-200}"
	if ! [[ "$period" =~ ^[0-9]+$ ]] || [[ "$period" -lt 10 ]]; then
		echo "install-full-server: неверный MTPRO_STATS_PRINT_PERIOD=${period}, использую 120" >&2
		period=120
	fi
	if ! [[ "$ips_len" =~ ^[0-9]+$ ]]; then
		echo "install-full-server: неверный MTPRO_CLIENT_IPS_LEN=${ips_len}, использую 200" >&2
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_WEB="${SCRIPT_DIR}/web"
PROXY_SCRIPT="${MTPROTO_INSTALL_SCRIPT:-/root/MTProtoProxyInstall.sh}"
INSTALLER_URL="${MTPROTO_INSTALLER_URL:-https://raw.githubusercontent.com/HirbodBehnam/MTProtoProxyInstaller/master/MTProtoProxyInstall.sh}"

INSTALL_ROOT="/opt/mtproto-web"
ENV_FILE="/etc/mtproto-web.env"
UNIT_FILE="/etc/systemd/system/mtproto-web.service"
NGX_SITE="/etc/nginx/sites-available/mtproto-panel"
CREDS_FILE="/root/mtproto-panel-access.txt"
INTERNAL_PORT="${MTPRO_INTERNAL_PANEL_PORT:-18080}"
SSL_PORT="${MTPRO_NGINX_SSL_PORT:-8443}"

SKIP_PROXY=false
YES_ALL=false
PROXY_NO_SECRETS=false
for a in "$@"; do
	case "$a" in
	--skip-proxy) SKIP_PROXY=true ;;
	-y | --yes) YES_ALL=true ;;
	--proxy-no-secrets) PROXY_NO_SECRETS=true ;;
	esac
done

[[ -f "${SRC_WEB}/app.py" ]] || die "Нужна папка web/ рядом со скриптом."
$SKIP_PROXY && $PROXY_NO_SECRETS && die "Нельзя вместе --skip-proxy и --proxy-no-secrets"
$PROXY_NO_SECRETS && [[ ! -f "${SCRIPT_DIR}/install-mtproto-proxy-headless.sh" ]] && die "Для --proxy-no-secrets нужен install-mtproto-proxy-headless.sh рядом со скриптом."
$PROXY_NO_SECRETS && [[ ! -f "${SCRIPT_DIR}/bundled-mtprotoproxy/mtprotoproxy.py" ]] && die "Нет bundled-mtprotoproxy/mtprotoproxy.py — выполните bash scripts/update-mtprotoproxy-bundle.sh и закоммитьте каталог."

rand_slug() {
	# Не использовать tr|head от /dev/urandom: при set -o pipefail head закрывает pipe → SIGPIPE у tr → немой выход скрипта
	openssl rand -hex 10
}

write_env_file() {
	# аргументы: user pass session install_script public_ip https_only slug
	python3 - "$@" <<'PY'
import pathlib
import sys

def q(s: str) -> str:
    # systemd в кавычках подставляет $ — экранируем как $$
    t = s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "$$")
    return '"' + t + '"'

path = pathlib.Path(sys.argv[1])
user, password, sess, script, pub_ip, https_only, slug = sys.argv[2:9]
lines = [
    "# mtproto-web: chmod 600; after edits run: systemctl restart mtproto-web",
    f"MTPROTO_WEB_USER={q(user)}",
    f"MTPROTO_WEB_PASSWORD={q(password)}",
    f"MTPROTO_WEB_SESSION_SECRET={q(sess)}",
    f"MTPROTO_INSTALL_SCRIPT={q(script)}",
    "MTPROTO_CONFIG=/opt/mtprotoproxy/config.py",
    f"MTPROTO_PUBLIC_IP={q(pub_ip)}",
    f"MTPROTO_SESSION_HTTPS_ONLY={q(https_only)}",
    f"MTPRO_PANEL_PATH={q(slug)}",
    "",
]
path.write_text("\n".join(lines), encoding="utf-8")
path.chmod(0o600)
PY
}

export DEBIAN_FRONTEND=noninteractive
info "Базовые пакеты (curl, python, nginx)…"
apt-get update -qq
apt-get install -y -qq curl ca-certificates openssl python3 python3-pip python3-venv nginx bsdutils

step "Скачивание MTProtoProxyInstall.sh → ${PROXY_SCRIPT}"
tmp_dl="$(mktemp)"
curl -fsSL -o "${tmp_dl}" "${INSTALLER_URL}" || die "Не удалось скачать установщик прокси"
install -m 0755 "${tmp_dl}" "${PROXY_SCRIPT}"
rm -f "${tmp_dl}"

if $SKIP_PROXY; then
	[[ -d /opt/mtprotoproxy ]] || warn "Нет /opt/mtprotoproxy — панель не сможет управлять прокси."
elif [[ -d /opt/mtprotoproxy ]]; then
	info "Прокси уже установлен, мастер пропущен."
	if ! $YES_ALL; then
		read -r -p "Открыть меню MTProtoProxyInstall.sh? [y/N]: " o
		[[ "${o,,}" == "y" ]] && bash "${PROXY_SCRIPT}" || true
	fi
else
	if $PROXY_NO_SECRETS; then
		step "Прокси без мастера секретов (USERS={}); порт ${MTPRO_PROXY_PORT:-443}"
		bash "${SCRIPT_DIR}/install-mtproto-proxy-headless.sh" || die "Тихая установка прокси не удалась"
	elif $YES_ALL; then
		die "Режим --yes без --proxy-no-secrets: сначала установите прокси вручную или запустите с --proxy-no-secrets, либо --skip-proxy если прокси уже есть"
	else
		step "Установка MTProto-прокси (интерактивный мастер)"
		bash "${PROXY_SCRIPT}" || die "Установка прокси прервалась"
	fi
	[[ -d /opt/mtprotoproxy ]] || die "Нет /opt/mtprotoproxy после установки прокси"
fi

if [[ -f /opt/mtprotoproxy/config.py ]]; then
	step "Проверка config.py: STATS_PRINT_PERIOD и CLIENT_IPS_LEN для панели"
	mtproto_ensure_panel_journal_options /opt/mtprotoproxy/config.py
fi

PANEL_SLUG="$(rand_slug)"
[[ ${#PANEL_SLUG} -ge 16 ]] || die "Не удалось сгенерировать путь панели"

if $YES_ALL; then
	WEB_USER="${MTPROTO_WEB_USER:-admin$(openssl rand -hex 3)}"
	WEB_PASS="${MTPROTO_WEB_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}"
elif [[ -r /dev/tty ]]; then
	# Ввод с /dev/tty: после apt иногда «съедается» stdin — иначе read падает с set -e и панель не ставится
	step "Учётная запись панели"
	uin=""
	read -r -p "Логин панели [admin]: " uin </dev/tty || true
	WEB_USER="${uin:-admin}"
	pin=""
	read -r -s -p "Пароль панели (пусто = сгенерировать): " pin </dev/tty || true
	echo >/dev/tty
	if [[ -z "${pin}" ]]; then
		WEB_PASS="$(openssl rand -base64 24 | tr -d '\n')"
		info "Сгенерирован пароль (см. также ${CREDS_FILE})"
	else
		pin2=""
		read -r -s -p "Повторите пароль: " pin2 </dev/tty || true
		echo >/dev/tty
		[[ "$pin" == "$pin2" ]] || die "Пароли не совпадают"
		WEB_PASS="$pin"
	fi
elif [[ -t 0 ]]; then
	step "Учётная запись панели"
	uin=""
	read -r -p "Логин панели [admin]: " uin || true
	WEB_USER="${uin:-admin}"
	pin=""
	read -r -s -p "Пароль панели (пусто = сгенерировать): " pin || true
	echo
	if [[ -z "${pin}" ]]; then
		WEB_PASS="$(openssl rand -base64 24 | tr -d '\n')"
		info "Сгенерирован пароль (см. также ${CREDS_FILE})"
	else
		pin2=""
		read -r -s -p "Повторите пароль: " pin2 || true
		echo
		[[ "$pin" == "$pin2" ]] || die "Пароли не совпадают"
		WEB_PASS="$pin"
	fi
else
	# Без TTY read даёт код 1 → при set -e скрипт раньше обрывался здесь (не было панели и access.txt)
	warn "Нет интерактивного ввода (stdin не терминал) — логин и пароль для панели сгенерированы автоматически."
	info "Смотрите ${CREDS_FILE} или задайте MTPROTO_WEB_USER / MTPROTO_WEB_PASSWORD и перезапустите скрипт с --yes."
	WEB_USER="${MTPROTO_WEB_USER:-admin$(openssl rand -hex 3)}"
	WEB_PASS="${MTPROTO_WEB_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}"
fi

SESSION_SECRET="$(openssl rand -hex 32)"
PUBLIC_IP="${MTPROTO_PUBLIC_IP:-}"
if [[ -z "$PUBLIC_IP" ]]; then
	PUBLIC_IP="$(curl -fsS https://api.ipify.org 2>/dev/null || true)"
fi
[[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="YOUR_IP"

# Повторный запуск: уже работающий mtproto-web держит INTERNAL_PORT — иначе проверка ниже мешает обновлению
if systemctl is-active --quiet mtproto-web.service 2>/dev/null; then
	info "Останавливаю mtproto-web, чтобы освободить порт ${INTERNAL_PORT}…"
	systemctl stop mtproto-web.service || true
	sleep 0.5
fi

if ss -tln 2>/dev/null | grep -qE ":${INTERNAL_PORT}\\s"; then
	die "Порт ${INTERNAL_PORT} занят. Задайте другой: export MTPRO_INTERNAL_PANEL_PORT=..."
fi
if ss -tln 2>/dev/null | grep -qE ":${SSL_PORT}\\s"; then
	warn "Порт ${SSL_PORT} занят — пробую 8444"
	SSL_PORT=8444
fi

info "Копирование панели в ${INSTALL_ROOT}…"
mkdir -p "${INSTALL_ROOT}"
cp -a "${SRC_WEB}/." "${INSTALL_ROOT}/"
VENV_PY="${INSTALL_ROOT}/venv/bin/python3"
VENV_PIP="${INSTALL_ROOT}/venv/bin/pip"
python3 -m venv "${INSTALL_ROOT}/venv"
"${VENV_PIP}" install -q --upgrade pip
"${VENV_PIP}" install -q -r "${INSTALL_ROOT}/requirements.txt"

write_env_file "${ENV_FILE}" "${WEB_USER}" "${WEB_PASS}" "${SESSION_SECRET}" "${PROXY_SCRIPT}" "${PUBLIC_IP}" "1" "${PANEL_SLUG}"

cat >"${UNIT_FILE}" <<EOF
[Unit]
Description=mtproxy web panel (FastAPI)
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_ROOT}
EnvironmentFile=${ENV_FILE}
Environment=PYTHONUNBUFFERED=1
ExecStart=${VENV_PY} -m uvicorn app:app --host 127.0.0.1 --port ${INTERNAL_PORT}
Restart=on-failure
RestartSec=5
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mtproto-web.service
systemctl restart mtproto-web.service

wait_health() {
	local n
	for n in $(seq 1 60); do
		if curl -sfS --connect-timeout 2 "http://127.0.0.1:${INTERNAL_PORT}/api/health" >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.5
	done
	return 1
}
if ! wait_health; then
	echo "" >&2
	echo "--- journalctl -u mtproto-web -n 60 (no pager) ---" >&2
	journalctl -u mtproto-web -n 60 --no-pager >&2 || true
	die "Панель не отвечает на http://127.0.0.1:${INTERNAL_PORT}/api/health — см. journalctl выше"
fi

install -d -m 0755 /etc/ssl/private 2>/dev/null || true
openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
	-keyout /etc/ssl/private/mtproto-panel.key \
	-out /etc/ssl/certs/mtproto-panel.crt \
	-subj "/CN=${PUBLIC_IP}/O=mtproto-panel" 2>/dev/null
chmod 0640 /etc/ssl/private/mtproto-panel.key

# Случайный префикс URL: /SLUG/ → бэкенд /
cat >"${NGX_SITE}" <<EOF
# Панель mtproxy — секретный путь + HTTPS
server {
    listen ${SSL_PORT} ssl;
    server_name _;

    ssl_certificate     /etc/ssl/certs/mtproto-panel.crt;
    ssl_certificate_key /etc/ssl/private/mtproto-panel.key;

    location = /${PANEL_SLUG} {
        return 302 /${PANEL_SLUG}/;
    }
    location /${PANEL_SLUG}/ {
        rewrite ^/${PANEL_SLUG}/(.*)\$ /\$1 break;
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_connect_timeout 15s;
        proxy_read_timeout 120s;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = / {
        return 404;
    }
}
EOF

ln -sf "${NGX_SITE}" /etc/nginx/sites-enabled/mtproto-panel
[[ -L /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl restart nginx

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
	ufw allow "${SSL_PORT}/tcp" comment 'mtproto panel https' || true
fi

PANEL_URL="https://${PUBLIC_IP}:${SSL_PORT}/${PANEL_SLUG}/"
{
	echo "mtproxy — доступ к панели управления"
	echo "Создано: $(date -Iseconds)"
	echo ""
	echo "URL:     ${PANEL_URL}"
	echo "Логин:   ${WEB_USER}"
	echo "Пароль:  ${WEB_PASS}"
	echo ""
	echo "Секретный путь (копировать вместе с URL): ${PANEL_SLUG}"
	echo "Настройки: ${ENV_FILE}"
	echo "Внутренний порт uvicorn (только localhost): ${INTERNAL_PORT}"
	echo "Прокси: systemctl status mtprotoproxy"
} | tee "${CREDS_FILE}"
chmod 0600 "${CREDS_FILE}"

echo ""
echo -e "${BOLD}${GRN}Готово.${RST}"
echo -e "${BOLD}Откройте в браузере:${RST} ${PANEL_URL}"
echo -e "${BOLD}Логин / пароль:${RST} ${WEB_USER} / (в файле ${CREDS_FILE})"
echo ""
warn "Сертификат самоподписанный — браузер покажет предупреждение."
warn "Откройте TCP ${SSL_PORT} в Security Group облака."
warn "Секретный путь не заменяет пароль; храните ${CREDS_FILE} в секрете."
