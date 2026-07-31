#!/usr/bin/env bash
# Встановлення: симлінки в ~/.local/bin + systemd user-юніти.
# Скрипти лишаються жити в репозиторії — правки діють одразу, без перевстановлення.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
UNITS="$HOME/.config/systemd/user"

mkdir -p "$BIN" "$UNITS"

for s in dev-clean.sh dev-clean-watch.sh; do
  chmod +x "$REPO/$s"
  ln -sfn "$REPO/$s" "$BIN/$s"
  echo "symlink: $BIN/$s → $REPO/$s"
done

for u in "$REPO"/systemd/*; do
  cp "$u" "$UNITS/"
  echo "unit: $UNITS/$(basename "$u")"
done

systemctl --user daemon-reload
systemctl --user enable --now dev-clean.timer dev-clean-watch.timer

echo
echo "Готово. Активні таймери:"
systemctl --user list-timers 'dev-clean*' --all --no-pager
