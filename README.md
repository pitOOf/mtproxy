# mtproxy — MTProto-прокси и веб-панель

Установка MTProto-прокси (Python-движок из [alexbers/mtprotoproxy](https://github.com/alexbers/mtprotoproxy), MIT, в каталоге `bundled-mtprotoproxy/`) и веб-панели на **FastAPI**. Режим **`--proxy-no-secrets`** не качает прокси с GitHub при установке — всё уже в репозитории.

**Репозиторий:** [https://github.com/pitOOf/mtproxy](https://github.com/pitOOf/mtproxy)

Подробная пошаговая инструкция: **[INSTALL.md](INSTALL.md)**.

---

## Быстрый старт (новый сервер Ubuntu)

1. **Откройте в облаке порты:** **TCP 8443** (панель), **TCP 443** (прокси, если в `config/mtprotoproxy-config.py` указан `PORT = 443`).

2. **Клонируйте и установите одной сессией SSH:**

```bash
sudo apt-get update -qq && sudo apt-get install -y -qq git
cd /root
sudo git clone https://github.com/pitOOf/mtproxy.git
cd mtproxy
sudo bash install-full-server.sh --proxy-no-secrets --yes
```

3. **Данные для входа** (URL, логин, пароль):

```bash
sudo cat /root/mtproto-panel-access.txt
```

4. Откройте URL в браузере (самоподписанный сертификат — предупреждение нормально), войдите и **создайте пользователей прокси** в панели.

**Опционально** перед установкой, если внешний IP для ссылок `tg://` нужно задать вручную:

```bash
export MTPROTO_PUBLIC_IP=203.0.113.50
sudo -E bash install-full-server.sh --proxy-no-secrets --yes
```

Редактировать скрипты на сервере **не обязательно**. Конфиг прокси по умолчанию — **`config/mtprotoproxy-config.py`** в репозитории (порт, TLS, лимиты); секреты `USERS` в публичный git не коммитьте — оставьте `{}` и заводите пользователей в панели.

---

## Требования

- **Ubuntu** 22.04 / 24.04 (или совместимый **Debian**)
- Права **root** / **sudo**
- Свободные порты: **443** под прокси (или другой `PORT` в конфиге), **8443** под HTTPS панели (или `MTPRO_NGINX_SSL_PORT`)

---

## Другие сценарии установки

### Полный стек, логин/пароль панели вручную

```bash
cd /root/mtproxy
sudo bash install-full-server.sh --proxy-no-secrets
```

### Только панель + nginx (прокси уже в `/opt/mtprotoproxy`)

```bash
cd /root/mtproxy
sudo bash install-full-server.sh --skip-proxy --yes
```

### Только веб-панель без сценария «полный сервер»

Прокси должен быть установлен, путь к `MTProtoProxyInstall.sh` — в переменной или по умолчанию `/root/MTProtoProxyInstall.sh`.

```bash
cd /root/mtproxy
sudo bash install-web-panel.sh
```

Неинтерактивно:

```bash
export MTPROTO_WEB_USER=admin
export MTPROTO_WEB_PASSWORD='надёжный-пароль'
cd /root/mtproxy
sudo -E bash install-web-panel.sh --yes
```

### Интерактивный установщик Hirbod (без `--proxy-no-secrets`)

Скачивается `MTProtoProxyInstall.sh`, мастер в консоли. Нужен обычный SSH с TTY.

```bash
cd /root/mtproxy
sudo bash install-full-server.sh
```

**Не используйте** `install-full-server.sh --yes` **без** `--proxy-no-secrets` и **без** уже установленного прокси — скрипт завершится с ошибкой.

---

## Переменные окружения (частые)

| Переменная | Где используется | Смысл |
|------------|------------------|--------|
| `MTPROTO_INSTALL_SCRIPT` | панель, установка | Путь к `MTProtoProxyInstall.sh` |
| `MTPROTO_INSTALLER_URL` | `install-full-server.sh` | URL скачивания установщика Hirbod |
| `MTPRO_INTERNAL_PANEL_PORT` | `install-full-server.sh` | Внутренний порт uvicorn (по умолчанию 18080) |
| `MTPRO_NGINX_SSL_PORT` | `install-full-server.sh` | Внешний HTTPS порт nginx (по умолчанию 8443) |
| `MTPROTO_PUBLIC_IP` | панель, установка | IP в ссылках `tg://` (иначе ipify) |
| `MTPROTO_WEB_USER` / `MTPROTO_WEB_PASSWORD` | `--yes` | Учётная запись панели |
| `MTPRO_PROXY_PORT` | headless без `config/mtprotoproxy-config.py` | Порт в авто-сгенерированном `config.py` |
| `MTPRO_STATS_PRINT_PERIOD` | доп. в `config` | Интервал «Stats for …» в journal (сек.) |
| `MTPRO_CLIENT_IPS_LEN` | доп. в `config` | Учёт IP / New IPs в логе |
| `MTPROTO_PROXY_NOTES` | панель | Путь к JSON с комментариями (см. `web/app.py`) |

---

## Структура репозитория

В корне — **`.gitignore`** (venv, `__pycache__`, `.env`, `*.local.py`).

| Каталог / файл | Назначение |
|----------------|------------|
| `install-full-server.sh` | Прокси + панель + nginx + HTTPS и секретный путь |
| `install-web-panel.sh` | Только панель в `/opt/mtproto-web` |
| `install-mtproto-proxy-headless.sh` | Только прокси из `bundled-mtprotoproxy/` + `config/` |
| `bundled-mtprotoproxy/` | `mtprotoproxy.py`, `pyaes/`, `LICENSE` (upstream MIT) |
| `config/mtprotoproxy-config.py` | Конфиг прокси для деплоя |
| `scripts/update-mtprotoproxy-bundle.sh` | Обновить движок с alexbers/mtprotoproxy |
| `web/` | Панель: `app.py`, `static/`, `requirements.txt` |
| `LICENSE` | Лицензия вашего кода в репозитории |

Обновить движок локально: `bash scripts/update-mtprotoproxy-bundle.sh`, затем коммит.

---

## Обновление панели на сервере

```bash
cd /root/mtproxy
sudo git pull
sudo cp -a web/. /opt/mtproto-web/
sudo /opt/mtproto-web/venv/bin/pip install -r /opt/mtproto-web/requirements.txt
sudo systemctl restart mtproto-web
```

---

## Устранение неполадок

- **Интерактивный Hirbod «завис» на втором секрете** — запускайте из SSH с TTY.
- **`dpkg` lock** — дождитесь `unattended-upgrades`, повторите установку.
- **Панель не отвечает** — `journalctl -u mtproto-web -n 80 --no-pager`, зависимости из `web/requirements.txt`.
- **502 у nginx** — `proxy_pass`, порт и `MTPRO_PANEL_PATH` в `/etc/mtproto-web.env`.
- **Нет данных в панели по TCP / New IPs** — см. `STATS_PRINT_PERIOD`, `CLIENT_IPS_LEN` в `config/mtprotoproxy-config.py` и `journalctl -u mtprotoproxy`.

---

## 🙌 Благодарности

- **`bundled-mtprotoproxy/`** — MIT, Alexander Bersenev ([alexbers/mtprotoproxy](https://github.com/alexbers/mtprotoproxy)). - за отличный движок прокси.
