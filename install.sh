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

# Конфіг apt потребує root, тож install.sh його не ставить — лише підказує, якщо його немає
# або він застарів. Копією, а не симлінком: файл у $HOME дав би змінювати конфіг, який apt читає від root.
if [ -d /etc/apt/apt.conf.d ] && ! cmp -s "$REPO/apt/99dev-clean" /etc/apt/apt.conf.d/99dev-clean; then
  echo
  echo "Щоб apt не накопичував .deb, один раз виконай:"
  echo "  sudo install -m 644 $REPO/apt/99dev-clean /etc/apt/apt.conf.d/"
fi
