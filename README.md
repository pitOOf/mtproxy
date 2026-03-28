# mtproxy — MTProto-прокси и веб-панель

**Пошаговая установка на новый сервер:** см. **[INSTALL.md](INSTALL.md)**.

Набор скриптов для Ubuntu: установка MTProto-прокси (Python-движок **вендорится** в `bundled-mtprotoproxy/`, исходный проект — [alexbers/mtprotoproxy](https://github.com/alexbers/mtprotoproxy), MIT) и веб-панели (FastAPI). Режим `--proxy-no-secrets` **не клонирует** GitHub на сервер: файлы уже в репозитории. Опционально можно поставить прокси через интерактивный установщик Hirbod Behnam (`install-full-server.sh` без `--proxy-no-secrets`).

## Требования

- **Ubuntu** 22.04 / 24.04 (или совместимый Debian)
- Права **root** на сервере
- Открытые порты в облачном фаерволе (см. ниже)

## Рекомендуемая установка с нуля

1. Склонируйте или скопируйте **всю папку** репозитория (например `mtproxy`) на сервер вместе с `web/`, `bundled-mtprotoproxy/`, `config/`.

   Конфиг прокси для git: правьте **`config/mtprotoproxy-config.py`** (порт, `TLS_DOMAIN`, лимиты и т.д.). Секреты `USERS` в публичный репозиторий не кладите — оставьте `{}` и задавайте пользователей в панели, либо используйте приватный репозиторий.

   Обновить движок из upstream: `bash scripts/update-mtprotoproxy-bundle.sh`, затем коммит.

2. Выполните **один** из вариантов.

### Вариант A: полный стек (прокси + панель + HTTPS + секретный путь URL)

Ставит зависимости, прокси, панель на `127.0.0.1`, **nginx** с самоподписанным сертификатом на порту **8443** (по умолчанию), случайный префикс пути в URL. Логин, пароль и URL записываются в файл:

```bash
cd /root/mtproxy
sudo bash install-full-server.sh
```

Интерактивно запросит логин/пароль панели (чтение с `/dev/tty`, чтобы не ломаться после `apt`).

**Полностью автоматически** (логин/пароль сгенерируются):

```bash
sudo bash install-full-server.sh --yes
```

**Прокси без мастера секретов** (`USERS = {}` в `config.py`; секреты добавляете только в панели):

```bash
sudo bash install-full-server.sh --proxy-no-secrets
sudo bash install-full-server.sh --proxy-no-secrets --yes
```

**Прокси уже установлен** — только панель и nginx:

```bash
sudo bash install-full-server.sh --skip-proxy
sudo bash install-full-server.sh --skip-proxy --yes
```

3. Откройте в браузере URL из файла:

```bash
sudo cat /root/mtproto-panel-access.txt
```

4. В панели провайдера откройте **TCP** порт **8443** (или тот, что задали в `MTPRO_NGINX_SSL_PORT`). Порт прокси берётся из **`config/mtprotoproxy-config.py`** (`PORT`, по умолчанию 443); не должен конфликтовать с nginx.

### Вариант B: только панель (прокси уже есть)

```bash
sudo bash install-web-panel.sh
```

Интерактивно спросит логин, пароль, порт панели (по умолчанию 8080 на localhost). Прокси должен быть в `/opt/mtprotoproxy`, скрипт установщика — в `/root/MTProtoProxyInstall.sh` (или укажите путь). Доступ снаружи настраивайте через свой nginx / фаервол или смените `--host` в unit `mtproto-web` (по умолчанию только `127.0.0.1`).

Неинтерактивно:

```bash
export MTPROTO_WEB_USER=admin
export MTPROTO_WEB_PASSWORD='надёжный-пароль'
sudo -E bash install-web-panel.sh --yes
```

## Переменные окружения (частые)

| Переменная | Где используется | Смысл |
|------------|------------------|--------|
| `MTPROTO_INSTALL_SCRIPT` | панель, установка | Путь к `MTProtoProxyInstall.sh` |
| `MTPROTO_INSTALLER_URL` | `install-full-server.sh` | URL скачивания установщика прокси |
| `MTPRO_INTERNAL_PANEL_PORT` | `install-full-server.sh` | Внутренний порт uvicorn (по умолчанию 18080) |
| `MTPRO_NGINX_SSL_PORT` | `install-full-server.sh` | Внешний HTTPS порт nginx (по умолчанию 8443) |
| `MTPROTO_PUBLIC_IP` | панель, установка | IP в ссылках `tg://` (иначе ipify) |
| `MTPROTO_WEB_USER` / `MTPROTO_WEB_PASSWORD` | `--yes` | Учётная запись панели |
| `MTPRO_PROXY_PORT` | headless без `config/mtprotoproxy-config.py` | Порт в сгенерированном `config.py` (по умолчанию 443); если файл из репозитория есть — смотрите `PORT` в нём |
| `MTPRO_STATS_PRINT_PERIOD` | headless + доп. в `config` из full/web | Интервал «Stats for …» в journal, сек. (по умолчанию 120) |
| `MTPRO_CLIENT_IPS_LEN` | headless + доп. в `config` из full/web | Учёт IP / New IPs в логе (по умолчанию 200; 0 = выкл.) |
| `MTPROTO_PROXY_NOTES` | панель (`app.py`) | Путь к JSON с комментариями к прокси-пользователям |

## Структура репозитория

В корне есть **`.gitignore`** — кэши Python, venv и шаблоны локальных секретов (`*.local.py`) в git не попадут.

| Файл / каталог | Назначение |
|----------------|------------|
| `install-full-server.sh` | Прокси + панель + nginx + HTTPS и секретный путь; при необходимости дописывает в `config.py` `STATS_PRINT_PERIOD` / `CLIENT_IPS_LEN` |
| `install-web-panel.sh` | Только веб-панель в `/opt/mtproto-web` |
| `install-mtproto-proxy-headless.sh` | Копирует `bundled-mtprotoproxy/` → `/opt/mtprotoproxy`, конфиг из `config/mtprotoproxy-config.py` (`--proxy-no-secrets`) |
| `bundled-mtprotoproxy/` | `mtprotoproxy.py`, `pyaes/`, `LICENSE` (MIT, Alexander Bersenev) |
| `config/mtprotoproxy-config.py` | Шаблон/ваш конфиг для прокси (коммит в git) |
| `scripts/update-mtprotoproxy-bundle.sh` | Подтянуть новую версию движка с GitHub alexbers |
| `web/` | Панель: `app.py`, `static/`, `requirements.txt` |

## Обновление панели

Скопируйте новые файлы из `web/` в `/opt/mtproto-web/`, обновите зависимости и перезапустите сервис:

```bash
sudo cp -a web/. /opt/mtproto-web/
sudo /opt/mtproto-web/venv/bin/pip install -r /opt/mtproto-web/requirements.txt
sudo systemctl restart mtproto-web
```

Повторный запуск `install-full-server.sh --skip-proxy --yes` остановит сервис, обновит конфиг и перезапишет slug/пароль, если не задать переменные — для обычного обновления кода удобнее команды выше.

## Устранение неполадок

- **Интерактивный установщик прокси «завис» на втором секрете** — запускайте `MTProtoProxyInstall.sh` из обычного SSH-сеанса с TTY, не из скриптов без псевдотерминала.
- **`dpkg` lock`** — дождитесь окончания `unattended-upgrades` или цикла ожидания блокировки, затем повторите установку.
- **Панель не отвечает на health** — `journalctl -u mtproto-web -n 80 --no-pager`; проверьте зависимости из `web/requirements.txt` (в т.ч. `itsdangerous`).
- **Порт занят при повторной установке** — скрипт останавливает `mtproto-web` перед проверкой; при конфликте смените `MTPRO_INTERNAL_PANEL_PORT`.
- **502 у nginx** — проверьте `proxy_pass` на актуальный внутренний порт и префикс пути из `/etc/mtproto-web.env` (`MTPRO_PANEL_PATH`).

## Лицензии и безопасность

Код в `bundled-mtprotoproxy/` — **MIT**, автор Alexander Bersenev (см. `bundled-mtprotoproxy/LICENSE`); вендорится для автономной установки. Установщик Hirbod — отдельный проект. Панель — дополнение к ним. Используйте **HTTPS** для входа в панель (`MTPROTO_SESSION_HTTPS_ONLY=1` за reverse-proxy). Самоподписанный сертификат браузер будет предупреждать; для продакшена рассмотрите Let’s Encrypt.
