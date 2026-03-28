"""
Веб-панель для mtproxy (установка MTProto-прокси и управление пользователями).
Запуск на сервере Ubuntu (от root или через sudo на скрипт установки).

  export MTPROTO_INSTALL_SCRIPT=/root/MTProtoProxyInstall.sh
  export MTPROTO_WEB_USER=admin
  export MTPROTO_WEB_PASSWORD='надёжный-пароль'
  export MTPROTO_WEB_SESSION_SECRET=$(openssl rand -hex 32)
  # опционально: фиксированный IP для ссылок tg:// (если ipify не подходит)
  # export MTPROTO_PUBLIC_IP=x.x.x.x
  # за HTTPS через nginx: export MTPROTO_SESSION_HTTPS_ONLY=1
  export MTPROTO_CONFIG=/opt/mtprotoproxy/config.py
  cd web && python3 -m uvicorn app:app --host 127.0.0.1 --port 8080
"""

from __future__ import annotations

import binascii
import importlib
import importlib.util
import json
import os
import re
import secrets
import subprocess
import sys
import urllib.request
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from starlette.middleware.sessions import SessionMiddleware

SCRIPT_PATH = Path(os.environ.get("MTPROTO_INSTALL_SCRIPT", "/root/MTProtoProxyInstall.sh"))
CONFIG_PATH = Path(os.environ.get("MTPROTO_CONFIG", "/opt/mtprotoproxy/config.py"))
WEB_ROOT = Path(__file__).resolve().parent / "static"
NOTES_PATH = Path(
    os.environ.get("MTPROTO_PROXY_NOTES", str(Path(__file__).resolve().parent / "proxy-user-notes.json"))
)

_PROXY_NAME_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")
# Имя модуля фиксировано: importlib.reload перечитывает config.py с диска после правок установщика
_CONFIG_MODULE_NAME = "mtproto_web_live_config"

SESSION_SECRET = os.environ.get("MTPROTO_WEB_SESSION_SECRET", "").strip()
WEB_USER = os.environ.get("MTPROTO_WEB_USER", "").strip()
WEB_PASS = os.environ.get("MTPROTO_WEB_PASSWORD", "")

_JOURNAL_STAT_LINE = re.compile(
    r"^([^:]+): (\d+) connects \((\d+) current\), ([\d.]+) MB, (\d+) msgs$"
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    if not SESSION_SECRET:
        raise RuntimeError("Задайте MTPROTO_WEB_SESSION_SECRET (например: openssl rand -hex 32)")
    if not WEB_USER or not WEB_PASS:
        raise RuntimeError("Задайте непустые MTPROTO_WEB_USER и MTPROTO_WEB_PASSWORD")
    yield


app = FastAPI(title="mtproxy — панель", lifespan=lifespan)

app.add_middleware(
    SessionMiddleware,
    secret_key=SESSION_SECRET,
    max_age=60 * 60 * 24 * 7,
    same_site="lax",
    https_only=os.environ.get("MTPROTO_SESSION_HTTPS_ONLY", "").lower() in ("1", "true", "yes"),
)


def load_config_module():
    """Всегда перечитывает config.py с диска (после правок установщиком кэш import мешал)."""
    if not CONFIG_PATH.is_file():
        return None
    path = str(CONFIG_PATH.resolve())
    spec = importlib.util.spec_from_file_location(_CONFIG_MODULE_NAME, path)
    if spec is None or spec.loader is None:
        return None
    existing = sys.modules.get(_CONFIG_MODULE_NAME)
    if existing is not None:
        try:
            return importlib.reload(existing)
        except Exception:
            del sys.modules[_CONFIG_MODULE_NAME]
    mod = importlib.util.module_from_spec(spec)
    sys.modules[_CONFIG_MODULE_NAME] = mod
    spec.loader.exec_module(mod)
    return mod


def concurrent_users_from_installer_tcp_cap(tcp_cap: int | None) -> int | None:
    """Официальный установщик кладёт в USER_MAX_TCP_CONNS значение «пользователей»×8 (TCP)."""
    if tcp_cap is None or tcp_cap <= 0:
        return None
    if tcp_cap % 8 != 0:
        return None
    return tcp_cap // 8


def parse_user_max_tcp_conns(mod: Any) -> dict[str, int]:
    """Имя пользователя прокси (ключ USERS) -> лимит одновременных TCP (USER_MAX_TCP_CONNS)."""
    if mod is None:
        return {}
    raw = getattr(mod, "USER_MAX_TCP_CONNS", None)
    if not isinstance(raw, dict):
        return {}
    out: dict[str, int] = {}
    for k, v in raw.items():
        try:
            out[str(k)] = int(v)
        except (TypeError, ValueError):
            continue
    return out


def public_ip() -> str:
    override = os.environ.get("MTPROTO_PUBLIC_IP", "").strip()
    if override:
        return override
    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=8) as r:
            return r.read().decode().strip()
    except Exception:
        return "YOUR_IP"


def parse_mtproto_stats_from_journal() -> dict[str, Any] | None:
    """Последний снимок из journalctl: TCP по USERS и список New IPs (alexbers/mtprotoproxy)."""
    try:
        p = subprocess.run(
            [
                "journalctl",
                "-u",
                "mtprotoproxy",
                "-n",
                "4000",
                "--no-pager",
                "-o",
                "cat",
            ],
            capture_output=True,
            text=True,
            timeout=45,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0 or not (p.stdout or "").strip():
        return None
    lines = p.stdout.splitlines()
    start = None
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].startswith("Stats for "):
            start = i
            break
    if start is None:
        return None
    hdr_line = lines[start]
    header = (
        hdr_line[len("Stats for ") :].strip()
        if hdr_line.startswith("Stats for ")
        else hdr_line.strip()
    )
    per_user: dict[str, dict[str, Any]] = {}
    new_ips: list[str] = []
    i = start + 1
    n = len(lines)
    while i < n:
        s = lines[i].strip()
        if not s:
            i += 1
            continue
        if s.startswith("Stats for "):
            break
        if s.startswith("New IPs:"):
            i += 1
            while i < n:
                s2 = lines[i].strip()
                if not s2:
                    break
                if s2.startswith("Clients with") or s2.startswith("Stats for "):
                    break
                new_ips.append(s2)
                i += 1
            break
        if s.startswith("Clients with"):
            break
        m = _JOURNAL_STAT_LINE.match(s)
        if m:
            per_user[m.group(1)] = {
                "connects_total": int(m.group(2)),
                "tcp_current": int(m.group(3)),
                "traffic_mb": float(m.group(4)),
                "msgs": int(m.group(5)),
            }
            i += 1
            continue
        break
    return {"snapshot_label": header, "users": per_user, "new_ips": new_ips}


def proxy_link(secret_hex: str, tls_domain: str, server: str, port: int) -> str:
    tail = binascii.hexlify(tls_domain.encode("utf-8")).decode("ascii")
    s = f"ee{secret_hex}{tail}"
    return f"tg://proxy?server={server}&port={port}&secret={s}"


def _read_notes() -> dict[str, str]:
    if not NOTES_PATH.is_file():
        return {}
    try:
        raw = json.loads(NOTES_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError):
        return {}
    if not isinstance(raw, dict):
        return {}
    out: dict[str, str] = {}
    for k, v in raw.items():
        if isinstance(k, str) and isinstance(v, str):
            out[k] = v
    return out


def _write_notes(notes: dict[str, str]) -> None:
    NOTES_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = NOTES_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(notes, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(NOTES_PATH)
    try:
        NOTES_PATH.chmod(0o600)
    except OSError:
        pass


def _prune_notes(valid_usernames: set[str]) -> None:
    notes = _read_notes()
    pruned = {k: v for k, v in notes.items() if k in valid_usernames}
    if pruned != notes:
        _write_notes(pruned)


def run_installer(*args: str) -> dict[str, Any]:
    if not SCRIPT_PATH.is_file():
        raise HTTPException(503, detail="Скрипт установки не найден. Задайте MTPROTO_INSTALL_SCRIPT.")
    cmd = ["bash", str(SCRIPT_PATH), *args]
    try:
        p = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=180,
            cwd="/",
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(504, detail="Таймаут выполнения скрипта")
    out = (p.stdout or "").strip()
    err = (p.stderr or "").strip()
    if p.returncode != 0:
        msg = out or err or f"exit {p.returncode}"
        try:
            data = json.loads(out.splitlines()[-1])
            if isinstance(data, dict) and data.get("ok") is False:
                raise HTTPException(400, detail=data.get("msg", msg))
        except json.JSONDecodeError:
            pass
        raise HTTPException(400, detail=msg)
    if not out:
        return {"ok": True, "msg": ""}
    for line in reversed(out.strip().splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return {"ok": True, "raw": out.splitlines()[-1].strip()}


def require_login(request: Request) -> bool:
    if not request.session.get("auth"):
        raise HTTPException(401, detail="Требуется войти")
    return True


class LoginBody(BaseModel):
    username: str = Field(..., min_length=1)
    password: str = Field(..., min_length=1)


@app.get("/")
def index():
    f = WEB_ROOT / "index.html"
    if not f.is_file():
        raise HTTPException(404)
    return FileResponse(f)


@app.get("/api/health")
def health():
    return {"ok": True}


@app.post("/api/login")
def login(request: Request, body: LoginBody):
    u_ok = secrets.compare_digest(body.username.encode("utf-8"), WEB_USER.encode("utf-8"))
    p_ok = secrets.compare_digest(body.password.encode("utf-8"), WEB_PASS.encode("utf-8"))
    if not (u_ok and p_ok):
        raise HTTPException(401, detail="Неверный логин или пароль")
    request.session["auth"] = True
    return {"ok": True}


@app.post("/api/logout")
def logout(request: Request):
    request.session.clear()
    return {"ok": True}


@app.post("/api/panel/restart")
def restart_panel(_auth: bool = Depends(require_login)):
    # Ответ должен уйти до stop unit; nohup+фон — дочерний shell переживает остановку uvicorn
    cmd = (
        "nohup bash -c 'sleep 1; exec systemctl restart mtproto-web.service' "
        "</dev/null >/dev/null 2>&1 &"
    )
    subprocess.Popen(
        ["/bin/bash", "-c", cmd],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )
    return {
        "ok": True,
        "msg": "Перезапуск mtproto-web запланирован (через ~1 с). Обновите страницу через несколько секунд.",
    }


@app.get("/api/status")
def status(_auth: bool = Depends(require_login)):
    installed = CONFIG_PATH.is_file() and SCRIPT_PATH.is_file()
    active = False
    if installed:
        try:
            s = subprocess.run(
                ["systemctl", "is-active", "mtprotoproxy"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            active = s.stdout.strip() == "active"
        except Exception:
            pass
    return {"installed": installed, "service_active": active, "script": str(SCRIPT_PATH)}


@app.get("/api/info")
def info(_auth: bool = Depends(require_login)):
    mod = load_config_module()
    if mod is None:
        raise HTTPException(503, detail="Прокси не установлен или нет config.py")
    port = int(getattr(mod, "PORT", -1))
    tls = getattr(mod, "TLS_DOMAIN", "www.google.com")
    ip = public_ip()
    period = int(getattr(mod, "STATS_PRINT_PERIOD", 600))
    return {
        "public_ip": ip,
        "port": port,
        "tls_domain": tls,
        "stats_print_period_sec": period,
    }


@app.get("/api/stats")
def proxy_stats(_auth: bool = Depends(require_login)):
    """
    Текущие TCP-соединения по пользователю прокси (из последнего дампа в журнале).
    Не путать с «устройствами» в настройках аккаунта Telegram.
    """
    snap = parse_mtproto_stats_from_journal()
    mod = load_config_module()
    period = int(getattr(mod, "STATS_PRINT_PERIOD", 600)) if mod else 600
    if snap is None:
        return {
            "ok": False,
            "stats_print_period_sec": period,
            "users": {},
            "snapshot_label": None,
            "new_ips": [],
            "hint": "Нет строки «Stats for …» в логе (ещё не прошёл интервал STATS_PRINT_PERIOD) "
            "или нет доступа к journalctl. Уменьшите STATS_PRINT_PERIOD в config.py или проверьте права.",
        }
    snap["ok"] = True
    snap["stats_print_period_sec"] = period
    snap["hint"] = (
        "Один клиент Telegram может держать несколько TCP (часто до ~8). "
        "Список сессий аккаунта — только в Telegram → Настройки → Устройства."
    )
    return snap


@app.get("/api/users")
def list_users(_auth: bool = Depends(require_login)):
    data = run_installer("list")
    if not data.get("ok"):
        raise HTTPException(400, detail=data.get("msg", "Ошибка list"))
    users = data.get("msg")
    if not isinstance(users, dict):
        raise HTTPException(500, detail="Неожиданный ответ list")
    valid_names = {str(k) for k, v in users.items() if v is not None}
    _prune_notes(valid_names)
    notes = _read_notes()
    mod = load_config_module()
    tcp_limits = parse_user_max_tcp_conns(mod)
    port = int(getattr(mod, "PORT", -1)) if mod else -1
    tls = getattr(mod, "TLS_DOMAIN", "www.google.com") if mod else "www.google.com"
    ip = public_ip()
    rows = []
    for name, secret in users.items():
        if secret is None:
            continue
        lim = tcp_limits.get(str(name))
        rows.append(
            {
                "username": name,
                "secret": secret,
                "link": proxy_link(str(secret), str(tls), ip, port),
                "comment": notes.get(str(name), ""),
                "max_tcp_conns": lim,
                "max_concurrent_users": concurrent_users_from_installer_tcp_cap(lim),
            }
        )
    return {"users": rows}


class AddUserBody(BaseModel):
    username: str = Field(default="", max_length=64)
    secret: str | None = None
    comment: str = Field(default="", max_length=2000)


def _pick_generated_username(existing: set[str]) -> str:
    for _ in range(48):
        cand = "u" + secrets.token_hex(4)
        if cand not in existing:
            return cand
    raise HTTPException(500, detail="Не удалось подобрать свободное имя; задайте имя вручную")


@app.post("/api/users")
def add_user(body: AddUserBody, _auth: bool = Depends(require_login)):
    data = run_installer("list")
    if not data.get("ok"):
        raise HTTPException(400, detail=data.get("msg", "Ошибка list"))
    raw_users = data.get("msg")
    if not isinstance(raw_users, dict):
        raise HTTPException(500, detail="Неожиданный ответ list")
    existing = {str(k) for k, v in raw_users.items() if v is not None}

    name = (body.username or "").strip()
    if not name:
        name = _pick_generated_username(existing)
    elif not _PROXY_NAME_RE.match(name):
        raise HTTPException(
            400,
            detail="Имя: только латинские буквы, цифры, _ и - (до 64 символов)",
        )
    elif name in existing:
        raise HTTPException(400, detail="Пользователь с таким именем уже есть")

    args = ["4", name]
    if body.secret:
        args.append(body.secret.strip())
    result = run_installer(*args)
    comment = (body.comment or "").strip()
    if comment:
        notes = _read_notes()
        notes[name] = comment
        _write_notes(notes)
    return result


@app.delete("/api/users/{username}")
def revoke_user(username: str, _auth: bool = Depends(require_login)):
    result = run_installer("5", username)
    notes = _read_notes()
    notes.pop(username, None)
    _write_notes(notes)
    return result


class CommentBody(BaseModel):
    comment: str = Field(default="", max_length=2000)


@app.put("/api/users/{username}/comment")
def set_user_comment(username: str, body: CommentBody, _auth: bool = Depends(require_login)):
    data = run_installer("list")
    if not data.get("ok"):
        raise HTTPException(400, detail=data.get("msg", "Ошибка list"))
    users = data.get("msg")
    if not isinstance(users, dict) or username not in users or users.get(username) is None:
        raise HTTPException(404, detail="Пользователь не найден")
    notes = _read_notes()
    c = (body.comment or "").strip()
    if c:
        notes[username] = c
    else:
        notes.pop(username, None)
    _write_notes(notes)
    return {"ok": True, "comment": c}


class LimitsBody(BaseModel):
    max_users: int = Field(..., ge=0)


@app.put("/api/users/{username}/limits")
def set_limits(username: str, body: LimitsBody, _auth: bool = Depends(require_login)):
    result = run_installer("6", username, str(body.max_users))
    mod = load_config_module()
    tcp = parse_user_max_tcp_conns(mod).get(str(username))
    applied = {
        "max_tcp_conns": tcp,
        "max_concurrent_users": concurrent_users_from_installer_tcp_cap(tcp),
    }
    if isinstance(result, dict):
        out = dict(result)
        out["applied_limits"] = applied
        return out
    return {"ok": True, "raw": result, "applied_limits": applied}


class ExpiryBody(BaseModel):
    date: str = ""


@app.put("/api/users/{username}/expiry")
def set_expiry(username: str, body: ExpiryBody, _auth: bool = Depends(require_login)):
    args = ["7", username]
    if body.date.strip():
        args.append(body.date.strip())
    return run_installer(*args)


class QuotaBody(BaseModel):
    limit: str = ""


@app.put("/api/users/{username}/quota")
def set_quota(username: str, body: QuotaBody, _auth: bool = Depends(require_login)):
    args = ["8", username]
    if body.limit.strip():
        args.append(body.limit.strip())
    return run_installer(*args)
