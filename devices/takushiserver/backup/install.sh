#!/usr/bin/env bash
# Installs the systemd timers for backup.sh: a nightly backup and a monthly check. Rerun it after
# moving this repo or editing the files in systemd/.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
for unit in "$HERE"/systemd/*; do
  sed "s#@BACKUP_SH@#$HERE/backup.sh#g" "$unit" >"/etc/systemd/system/$(basename "$unit")"
done
systemctl daemon-reload
systemctl enable --now takushiserver-backup.timer takushiserver-backup-check.timer
systemctl list-timers 'takushiserver-backup*'
