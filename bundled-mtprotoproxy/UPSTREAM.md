# Вендоринг движка прокси

Исходники из репозитория **[alexbers/mtprotoproxy](https://github.com/alexbers/mtprotoproxy)** (ветка `master`, MIT License, см. `LICENSE`).

В каталоге только то, что нужно для запуска: `mtprotoproxy.py` и встроенный пакет `pyaes/`. Файл **`config.py` не копируется из upstream** — используется ваш из `../config/mtprotoproxy-config.py` в этом репозитории.

Обновить файлы из GitHub на машине разработчика:

```bash
bash scripts/update-mtprotoproxy-bundle.sh
```
