#!/usr/bin/env bash
# Щотижневе безпечне очищення dev-сміття.
# Принцип: видаляти лише те, що (а) автоматично відновлюється і (б) давно не використовувалось.
set -uo pipefail

# systemd дає мінімальний PATH — додаємо pnpm та ~/.local/bin
export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
export PATH="$PNPM_HOME:$HOME/.local/bin:$PATH"

# Логування у файл: journald для user-юнітів тут не персистентний, тому весь
# вивід дублюємо в ~/.local/state/dev-clean.log. Перезапускаємо себе під tee,
# щоб батьківський процес дочекався запису (простіше й надійніше за process substitution).
LOG="${DEV_CLEAN_LOG:-$HOME/.local/state/dev-clean.log}"
if [ -z "${DEV_CLEAN_LOGGING:-}" ]; then
  mkdir -p "$(dirname "$LOG")"
  # ротація: лог більший за 1 МБ обрізаємо до останніх 2000 рядків
  if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -n 2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
  export DEV_CLEAN_LOGGING=1
  set -o pipefail
  "$0" "$@" 2>&1 | tee -a "$LOG"
  exit "${PIPESTATUS[0]}"
fi

# причину запуску (якщо чистку викликав watch за переповненим диском) кладе туди dev-clean-watch.sh
REASON_FILE="$(dirname "$LOG")/dev-clean.reason"
DEV_CLEAN_REASON="$(cat "$REASON_FILE" 2>/dev/null || true)"
rm -f "$REASON_FILE"

# Пороги (усе перевизначається через env)
# Кілька коренів через пробіл: DEV_CLEAN_SCAN_ROOT="$HOME/Documents $HOME/code"
read -r -a SCAN_ROOTS <<< "${DEV_CLEAN_SCAN_ROOT:-$HOME/Documents}"
# Глибина обходу. Worktree лежить як worktrees/<repo>/<name>/<repo>/apps/<app>/.next/dev —
# це рівно 8 рівнів, тож 8 було впритул: беремо 10, щоб пережити ще пару рівнів вкладеності.
SCAN_DEPTH="${DEV_CLEAN_SCAN_DEPTH:-10}"
TURBO_CACHE_LIMIT_MB="${TURBO_CACHE_LIMIT_MB:-8192}"   # ліміт .turbo/cache на репозиторій
NEXT_DEV_STALE_DAYS="${NEXT_DEV_STALE_DAYS:-14}"       # вік .next/dev, після якого його видаляємо
RUST_TARGET_BIG_GB="${RUST_TARGET_BIG_GB:-20}"         # «завеликий» target/
RUST_TARGET_BIG_STALE_DAYS="${RUST_TARGET_BIG_STALE_DAYS:-7}"

echo "=== dev-clean $(date '+%F %T') ${DEV_CLEAN_REASON:+($DEV_CLEAN_REASON) }==="
df -h / | tail -1

# Обхід дерева проєктів: не спускаємось у node_modules/.git/target — це і швидше,
# і не дає знайти вкладені збіркові теки всередині залежностей.
# scan_dirs <ім'я-теки | -path-патерн>
scan_dirs() {
  # шукану теку не можна класти у prune-гілку: -o короткозамикається і вона не потрапить у вивід
  local prune=( -name node_modules -o -name .git )
  [ "$2" = "target" ] || prune+=( -o -name target )
  find "${SCAN_ROOTS[@]}" -maxdepth "$SCAN_DEPTH" \
    \( -type d \( "${prune[@]}" \) -prune \) -o \
    \( -type d "$1" "$2" -prune -print0 \) 2>/dev/null
}

# Обрізає теку кешу до ліміту, видаляючи найстаріші файли (LRU за mtime).
# trim_cache_dir <тека> <ліміт у МБ>
trim_cache_dir() {
  local dir="$1" limit_mb="$2" size_kb limit_kb excess_kb freed_kb=0 fsize fpath
  [ -d "$dir" ] || return 0
  size_kb="$(du -sk "$dir" 2>/dev/null | cut -f1)"
  limit_kb=$(( limit_mb * 1024 ))
  [ "${size_kb:-0}" -le "$limit_kb" ] && return 0
  excess_kb=$(( size_kb - limit_kb ))
  echo "trim cache: $dir ($(( size_kb / 1024 ))МБ > ${limit_mb}МБ)"
  while IFS=$'\t' read -r _ fsize fpath; do
    [ "$freed_kb" -ge "$excess_kb" ] && break
    rm -f "$fpath" 2>/dev/null || continue
    freed_kb=$(( freed_kb + (fsize + 1023) / 1024 ))
  done < <(find "$dir" -maxdepth 1 -type f -printf '%T@\t%s\t%p\n' 2>/dev/null | sort -n)
  echo "  звільнено ~$(( freed_kb / 1024 ))МБ"
}

# 1. Docker: кеш збірок, старіший за 2 тижні, + образи без тегів.
#    Контейнери та volumes НЕ чіпаємо — там можуть бути дані.
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  docker builder prune -f --filter until=336h 2>/dev/null \
    || docker builder prune -f --filter unused-for=336h
  docker image prune -f
fi

# 2. Rust target/, у яких 14+ днів нічого не змінювалось (поруч має бути Cargo.toml).
#    Ціна помилки — лише одна довга перезбірка, даних не втрачається.
#    Додатково: «завеликі» target/ (20+ ГБ) чистимо вже після 7 днів простою — саме вони
#    з'їдають диск в активних репо, де правило 14 днів ніколи не спрацьовує (zed: 96 ГБ).
scan_dirs -name target |
while IFS= read -r -d '' t; do
  [ -f "$(dirname "$t")/Cargo.toml" ] || continue
  if [ -z "$(find "$t" -newermt '14 days ago' -print -quit 2>/dev/null)" ]; then
    echo "rm target: $t ($(du -sh "$t" 2>/dev/null | cut -f1))"
    rm -rf "$t"
    continue
  fi
  # активний репозиторій — але якщо target роздувся і саме він давно не збирався, чистимо debug-профіль
  [ -d "$t/debug" ] || continue
  size_gb=$(( $(du -sk "$t" 2>/dev/null | cut -f1) / 1048576 ))
  [ "$size_gb" -ge "$RUST_TARGET_BIG_GB" ] || continue
  if [ -z "$(find "$t/debug" -newermt "$RUST_TARGET_BIG_STALE_DAYS days ago" -print -quit 2>/dev/null)" ]; then
    echo "rm target/debug: $t/debug (${size_gb}ГБ target, не збирався ${RUST_TARGET_BIG_STALE_DAYS}+ днів)"
    rm -rf "$t/debug"
  fi
done

# 3. node_modules у теках, де 60+ днів не було жодних змін (сам node_modules не рахується)
find "${SCAN_ROOTS[@]}" -maxdepth "$SCAN_DEPTH" \
  \( -type d \( -name .git -o -name target \) -prune \) -o \
  \( -type d -name node_modules -prune -print0 \) 2>/dev/null |
while IFS= read -r -d '' n; do
  repo="$(dirname "$n")"
  if [ -z "$(find "$repo" -name node_modules -prune -o -newermt '60 days ago' -print -quit 2>/dev/null)" ]; then
    echo "rm node_modules: $n ($(du -sh "$n" 2>/dev/null | cut -f1))"
    rm -rf "$n"
  fi
done

# 3b. Артефакти збірок у теках без змін 60+ днів. Видаляємо лише те,
#     що git сам вважає сміттям (check-ignore) — код під це не потрапить.
find "${SCAN_ROOTS[@]}" -maxdepth "$SCAN_DEPTH" \
  \( -type d \( -name node_modules -o -name .git \) -prune \) -o \
  \( -type d \( -name .next -o -name .turbo -o -name dist -o -name build -o -name .venv \
     -o -name venv -o -name __pycache__ -o -name .pytest_cache -o -name coverage \) \
  -prune -print0 \) 2>/dev/null |
while IFS= read -r -d '' a; do
  repo="$(dirname "$a")"
  git -C "$repo" check-ignore -q "$a" 2>/dev/null || continue
  if [ -z "$(find "$repo" -name node_modules -prune -o -path "$a" -prune -o -newermt '60 days ago' -print -quit 2>/dev/null)" ]; then
    echo "rm artifact: $a ($(du -sh "$a" 2>/dev/null | cut -f1))"
    rm -rf "$a"
  fi
done

# 3c. Кеш turborepo: спершу записи, старші 30 днів, потім ліміт розміру.
#     Ліміт обов'язковий: один запис кешу тягне десятки ГБ, тож 83 ГБ набігає за тиждень
#     і правило «старші 30 днів» не спрацьовує жодного разу. Втрата = лише cache miss.
scan_dirs -path '*/.turbo/cache' |
while IFS= read -r -d '' c; do
  find "$c" -type f -mtime +30 -delete 2>/dev/null
  trim_cache_dir "$c" "$TURBO_CACHE_LIMIT_MB"
done

# 3d. .next/dev — кеш turbopack dev-сервера (у doc2pay доростав до 6,8 ГБ на застосунок).
#     Відновлюється сам при наступному `next dev`, ціна — повільніший перший старт.
scan_dirs -path '*/.next/dev' |
while IFS= read -r -d '' d; do
  if [ -z "$(find "$d" -newermt "$NEXT_DEV_STALE_DAYS days ago" -print -quit 2>/dev/null)" ]; then
    echo "rm .next/dev: $d ($(du -sh "$d" 2>/dev/null | cut -f1))"
    rm -rf "$d"
  fi
done

# Чи можна довіряти atime на цьому диску (noatime → ні, лише mtime-TTL)
opts="$(findmnt -no OPTIONS --target "$HOME" 2>/dev/null || true)"

# 4. Кеші пакетних менеджерів — обрізати, не видаляти повністю
command -v pnpm >/dev/null && pnpm store prune 2>&1 | tail -1
# npm-кеш самовідновний: якщо файл зникне, npm просто перекачає пакет
if [[ "$opts" == *noatime* ]]; then
  find "$HOME/.npm/_cacache" -type f -mtime +90 -delete 2>/dev/null
else
  find "$HOME/.npm/_cacache" -type f -atime +30 -mtime +30 -delete 2>/dev/null
fi
command -v uv >/dev/null && uv cache prune -q 2>/dev/null
# cargo: викачані .crate, старші 90 днів (перекачаються при потребі)
find "$HOME/.cargo/registry/cache" -name '*.crate' -mtime +90 -delete 2>/dev/null

# 5. Кошик: лише покладене туди 30+ днів тому.
#    ctime оновлюється в момент переміщення в кошик; чистимо тільки верхній рівень,
#    щоб не випатрати зсередини нещодавно викинуту теку зі старими файлами.
TRASH="$HOME/.local/share/Trash"
if [ -d "$TRASH/files" ]; then
  find "$TRASH/files" -mindepth 1 -maxdepth 1 -ctime +30 -exec rm -rf {} + 2>/dev/null
  for i in "$TRASH"/info/*.trashinfo; do
    [ -e "$i" ] || break
    [ -e "$TRASH/files/$(basename "$i" .trashinfo)" ] || rm -f "$i"
  done
fi

# 6. ~/.cache: файли, яких 60+ днів ніхто не читав і не змінював.
#    atime надійний лише без noatime (типовий relatime підходить).
if [[ "$opts" == *noatime* ]]; then
  echo "skip ~/.cache: диск змонтовано з noatime, atime ненадійний"
else
  find "$HOME/.cache" -xdev -type f -atime +60 -mtime +60 -ctime +60 -delete 2>/dev/null
  find "$HOME/.cache" -mindepth 1 -xdev -type d -empty -delete 2>/dev/null
fi

# 7. Flatpak: рантайми, на які ніхто не посилається
command -v flatpak >/dev/null && flatpak uninstall --unused -y --noninteractive >/dev/null 2>&1

# Сповіщення, якщо диск усе одно переповнений
pct="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
if [ "${pct:-0}" -ge 85 ]; then
  notify-send -u critical "Диск заповнено на ${pct}%" "Автоочищення не вистачає — глянь du -sh ~/Documents/* або запусти bleachbit" 2>/dev/null || true
fi

df -h / | tail -1
echo "=== done ==="
