#!/bin/bash
# Скачивает в bundled-mtprotoproxy актуальные mtprotoproxy.py и pyaes из alexbers/mtprotoproxy (master).
# Запуск из корня репозитория mtproxy: bash scripts/update-mtprotoproxy-bundle.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST="${ROOT}/bundled-mtprotoproxy"
BASE="https://raw.githubusercontent.com/alexbers/mtprotoproxy/master"

mkdir -p "${DST}/pyaes"
curl -fsSL -o "${DST}/LICENSE" "${BASE}/LICENSE"
curl -fsSL -o "${DST}/mtprotoproxy.py" "${BASE}/mtprotoproxy.py"
for f in __init__.py aes.py blockfeeder.py util.py; do
	curl -fsSL -o "${DST}/pyaes/${f}" "${BASE}/pyaes/${f}"
done
echo "OK: ${DST}"
