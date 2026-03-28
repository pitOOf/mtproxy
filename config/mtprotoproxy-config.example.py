# Скопируйте в mtprotoproxy-config.py и правьте под себя (или переименуйте и коммитьте как основной файл).
# Секреты USERS можно оставить пустыми и задавать через веб-панель.

PORT = 443
TLS_DOMAIN = "www.cloudflare.com"
MODES = {"classic": False, "secure": False, "tls": True}

USERS = {}
USER_MAX_TCP_CONNS = {}
USER_EXPIRATIONS = {}
USER_DATA_QUOTA = {}

STATS_PRINT_PERIOD = 120
CLIENT_IPS_LEN = 200
