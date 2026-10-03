---
name: verify
description: Як запустити dev-clean.sh / install.sh у пісочниці, не чіпаючи справжній HOME і систему
---

# Верифікація dev-clean

Скрипт деструктивний — **ніколи не запускай його на справжньому HOME**. Лише в пісочниці:

- `HOME=<sandbox>/home DEV_CLEAN_SCAN_ROOT=<sandbox>/home/Documents DEV_CLEAN_LOG=<sandbox>/run.log ./dev-clean.sh`
- Шими в `<sandbox>/home/.local/bin` (скрипт сам додає його на початок PATH): `docker` → `exit 1`
  (інакше `docker builder/image prune` пройде по справжньому демону), `pnpm`, `uv`, `flatpak`, `notify-send` → echo.
- `/` і `/tmp` змонтовані з `noatime`, тож крок `~/.cache` пропускається. Щоб його пройти, додай шим `findmnt`, що друкує `rw,relatime`.

## Час

ctime фікстур не зістарити (він завжди «зараз»), а кроки `~/.cache` і кошика дивляться саме на нього.
Тому годинник зсувають уперед через LD_PRELOAD (faketime не встановлено):
маленький `.so`, що додає `TIMESHIFT_SEC` до `clock_gettime(CLOCK_REALTIME)`, `gettimeofday` і `time`
(`gcc -shared -fPIC -o ts.so ts.c -ldl`). Запуск: `LD_PRELOAD=ts.so TIMESHIFT_SEC=8640000` (+100 днів).
Тоді «старі» фікстури — це просто щойно створені файли, а «свіжі» ставлять `touch -m -d @$((now+95*86400))`
(для atime — `touch -a`).

Кошик перевіряй прогоном **без** зсуву: зі зсувом `-ctime +30` законно видаляє всі фікстури.

## Що варто ганяти

- pnpm-монорепо з давно не редагованим пакетом: його `node_modules` і `dist` мають лишитись;
- покинутий проєкт зі свіжим лише `.git/FETCH_HEAD`: `node_modules` має зникнути;
- Rust `target/` з `CACHEDIR.TAG` і без нього;
- `~/.cache`: застаріла тека, тека з одним свіжим за atime файлом, файл у корені, симлінк;
- контраст: `git show origin/develop:dev-clean.sh` на тих самих фікстурах.
- `install.sh`: копія репо в шлях із пробілом, шим `systemctl`, змінений `apt/99dev-clean`, щоб `cmp` не збігся і підказка надрукувалась.
