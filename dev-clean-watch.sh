#!/usr/bin/env bash
# Аварійний тригер автоочищення: щогодини дивиться на заповненість диска
# і запускає dev-clean.service, якщо вільного місця майже не лишилось.
set -uo pipefail

export PATH="$HOME/.local/bin:$PATH"

THRESHOLD="${DEV_CLEAN_THRESHOLD:-90}"   # % заповнення, за яким запускаємо чистку
COOLDOWN_H="${DEV_CLEAN_COOLDOWN_H:-6}"  # не частіше ніж раз на N годин
LOG="${DEV_CLEAN_LOG:-$HOME/.local/state/dev-clean.log}"

log() {
  mkdir -p "$(dirname "$LOG")"
  echo "[watch $(date '+%F %T')] $*" | tee -a "$LOG"
}

pct="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
[ "${pct:-0}" -ge "$THRESHOLD" ] || exit 0

# Антидребезг: якщо чистка щойно відпрацювала, повторний запуск нічого не дасть —
# місце тоді звільняє вже не скрипт, а користувач.
last="$(systemctl --user show dev-clean.service -p ExecMainStartTimestamp --value 2>/dev/null)"
if [ -n "$last" ]; then
  last_s="$(date -d "$last" +%s 2>/dev/null || echo 0)"
  if [ "$last_s" -gt 0 ] && [ $(( $(date +%s) - last_s )) -lt $(( COOLDOWN_H * 3600 )) ]; then
    log "диск ${pct}%, але dev-clean працював менш ніж ${COOLDOWN_H} год тому — пропуск"
    notify-send -u critical "Диск заповнено на ${pct}%" \
      "Автоочищення вже відпрацювало — звільни місце вручну (du -sh ~/Documents/* або bleachbit)" 2>/dev/null || true
    exit 0
  fi
fi

log "диск ${pct}% ≥ ${THRESHOLD}% — запускаю dev-clean.service"
notify-send "Диск заповнено на ${pct}%" "Запускаю автоочищення dev-кешів" 2>/dev/null || true
# причину передаємо файлом — dev-clean.sh прочитає й видалить його
echo "тригер: диск ${pct}%" > "$(dirname "$LOG")/dev-clean.reason"
systemctl --user start --no-block dev-clean.service
