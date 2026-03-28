# Конфиг MTProto-прокси для установки в /opt/mtprotoproxy/config.py
# Редактируйте и храните в git. Панель и установщик Hirbod могут менять USERS и лимиты на сервере.

PORT = 443
TLS_DOMAIN = "www.cloudflare.com"
MODES = {"classic": False, "secure": False, "tls": True}

USERS = {}
USER_MAX_TCP_CONNS = {}
USER_EXPIRATIONS = {}
USER_DATA_QUOTA = {}

STATS_PRINT_PERIOD = 120
CLIENT_IPS_LEN = 200
