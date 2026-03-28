# Установка на новый сервер

Пошаговая инструкция для **чистого Ubuntu** (22.04 / 24.04 или совместимый Debian) с правами **root** (через `sudo`).

---

## 1. Что понадобится

| Требование | Пояснение |
|------------|-----------|
| Сервер | VPS или железо с публичным IP |
| ОС | Ubuntu 22.04+ / Debian (как в скриптах) |
| Доступ | SSH под пользователем с `sudo` или сразу `root` |
| Порты | Открыть в **фаерволе облака** и на сервере (см. шаг 6) |

---

## 2. Подготовка конфигурации (по желанию до выкладки на сервер)

В репозитории отредактируйте **`config/mtprotoproxy-config.py`**:

- **`PORT`** — порт прокси (часто **443**; не должен совпадать с портом HTTPS панели **8443** по умолчанию).
- **`TLS_DOMAIN`** — домен для маски TLS (как в Telegram, например `www.cloudflare.com`).
- **`STATS_PRINT_PERIOD`**, **`CLIENT_IPS_LEN`** — для статистики в журнале и списка «New IPs» в панели.

Не коммитьте в публичный git реальные секреты в **`USERS`** — оставьте `USERS = {}` и создавайте пользователей прокси уже в веб-панели.

Убедитесь, что в репозитории есть каталог **`bundled-mtprotoproxy/`** с файлом **`mtprotoproxy.py`**. Если его нет, на машине с Linux/macOS:

```bash
bash scripts/update-mtprotoproxy-bundle.sh
```

---

## 3. Перенос проекта на сервер

Скопируйте **всю папку** проекта (с **`web/`**, **`bundled-mtprotoproxy/`**, **`config/`**, скриптами).

Примеры:

```bash
# С вашего ПК (если установлен scp)
scp -r mtproxy root@ВАШ_IP:/root/

# Или клонирование с GitHub (если репозиторий уже залит)
ssh root@ВАШ_IP
apt-get update -qq && apt-get install -y -qq git
git clone https://github.com/ВАШ_АКК/mtproxy.git   # или другое имя репозитория
cd mtproxy
```

Дальше в примерах путь к каталогу — `/root/mtproxy` (замените на свой, если клонировали в другое место).

---

## 4. Рекомендуемая установка: прокси + панель + HTTPS

Подходит для **нового сервера без установленного прокси**.

### Вариант А — полностью автоматически

Сгенерируются логин и пароль панели, URL с **случайным путём** и **самоподписанным HTTPS** на порту **8443**:

```bash
cd /root/mtproxy
sudo bash install-full-server.sh --proxy-no-secrets --yes
```

### Вариант Б — ввести логин и пароль панели вручную

```bash
cd /root/mtproxy
sudo bash install-full-server.sh --proxy-no-secrets
```

Скрипт задаст вопросы (в том числе логин/пароль панели с `/dev/tty`).

### Что делает сценарий

- Ставит системные пакеты, **Python**, **nginx**.
- Копирует прокси из **`bundled-mtprotoproxy/`** в **`/opt/mtprotoproxy`**, конфиг — из **`config/mtprotoproxy-config.py`**.
- При необходимости **дописывает** в **`/opt/mtprotoproxy/config.py`** строки **`STATS_PRINT_PERIOD`** и **`CLIENT_IPS_LEN`**, если их ещё нет (и перезапускает прокси).
- Устанавливает панель в **`/opt/mtproto-web`**, systemd-юнит **`mtproto-web`**.
- Настраивает **nginx**: HTTPS на **`MTPRO_NGINX_SSL_PORT`** (по умолчанию **8443**), префикс пути из случайной строки.
- Записывает **URL, логин и пароль** в файл:

```bash
sudo cat /root/mtproto-panel-access.txt
```

Откройте в браузере указанный **https://…** (браузер предупредит о самоподписанном сертификате — это нормально для теста).

---

## 5. Альтернативы

### Прокси уже стоит, нужны только панель и nginx

```bash
cd /root/mtproxy
sudo bash install-full-server.sh --skip-proxy
# или без вопросов:
sudo bash install-full-server.sh --skip-proxy --yes
```

Прокси должен быть в **`/opt/mtprotoproxy`**.

### Только веб-панель (без nginx из full-server)

Если прокси уже есть и внешний доступ к панели настроите сами:

```bash
cd /root/mtproxy
sudo bash install-web-panel.sh
```

Панель по умолчанию слушает **127.0.0.1** и порт **8080** (или тот, что зададите).

### Классический интерактивный установщик Hirbod (без `--proxy-no-secrets`)

```bash
cd /root/mtproxy
sudo bash install-full-server.sh
```

Нужен нормальный **SSH с TTY**; при добавлении **нескольких секретов** подряд без TTY ввод может «зависнуть».

---

## 6. Фаервол и порты

Откройте порты **у провайдера** (Security Group / Firewall) и при использовании **ufw** на сервере.

| Сервис | Порт (по умолчанию) | Назначение |
|--------|---------------------|------------|
| Панель (nginx) | **TCP 8443** | HTTPS вход в админку (`MTPRO_NGINX_SSL_PORT`) |
| MTProto proxy | **TCP 443** (или ваш `PORT` в `config/mtprotoproxy-config.py`) | Клиенты Telegram |
| SSH | **22** | Администрирование |

Пример для **ufw**:

```bash
sudo ufw allow 22/tcp
sudo ufw allow 8443/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
```

Если **443** занят (например, другим сайтом), смените **`PORT`** в **`config/mtprotoproxy-config.py`** **до** первой установки или отредактируйте **`/opt/mtprotoproxy/config.py`** и выполните:

```bash
sudo systemctl restart mtprotoproxy
```

---

## 7. После установки

1. Войти в панель по URL из **`/root/mtproto-panel-access.txt`**.
2. Создать пользователя прокси (если **`USERS`** был пустой).
3. Скопировать выданную ссылку **`tg://`** в Telegram.
4. Проверить сервисы:

```bash
sudo systemctl status mtprotoproxy --no-pager
sudo systemctl status mtproto-web --no-pager
sudo journalctl -u mtprotoproxy -n 30 --no-pager
sudo journalctl -u mtproto-web -n 30 --no-pager
```

---

## 8. Полезные переменные окружения (перед `sudo bash …`)

Имеет смысл задать **до** запуска установки, если значения по умолчанию не подходят:

```bash
export MTPROTO_PUBLIC_IP=203.0.113.50    # если ipify не подходит для ссылок tg://
export MTPRO_NGINX_SSL_PORT=9443        # внешний HTTPS панели
export MTPRO_INTERNAL_PANEL_PORT=18080 # внутренний порт uvicorn (редко нужно менять)
```

Для режима **`--yes`** задайте учётку панели явно (иначе сгенерируется):

```bash
export MTPROTO_WEB_USER=admin
export MTPROTO_WEB_PASSWORD='сложный-пароль'
```

Запуск с сохранением переменных:

```bash
sudo -E bash install-full-server.sh --proxy-no-secrets --yes
```

---

## 9. Обновление только файлов панели

```bash
cd /root/mtproxy
sudo cp -a web/. /opt/mtproto-web/
sudo /opt/mtproto-web/venv/bin/pip install -r /opt/mtproto-web/requirements.txt
sudo systemctl restart mtproto-web
```

---

## 10. Если что-то пошло не так

Кратко см. раздел **«Устранение неполадок»** в **`README.md`**: блокировка `dpkg`, health панели, конфликт портов, 502 у nginx.

Логи:

```bash
sudo journalctl -u mtproto-web -e
sudo journalctl -u mtprotoproxy -e
sudo nginx -t
```
