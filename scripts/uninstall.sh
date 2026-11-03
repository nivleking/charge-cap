#!/bin/bash
# Removes ChargeCap from the Mac and puts charging back to normal.
#
#   sudo scripts/uninstall.sh            switch the limit off, stop the daemon, remove the files
#   sudo scripts/uninstall.sh --purge    same, and also delete the config and the log
#        scripts/uninstall.sh --dry-run  show what would happen; changes nothing, no sudo
#
# Order matters: the limit is switched off FIRST, so the Mac never keeps a limit nobody maintains.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="dev.kelvin.chargecap"
LIBEXEC="/usr/local/libexec/chargecap"
CLI_DEST="/usr/local/bin/chargecap"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
CONFIG_DIR="/Library/Application Support/ChargeCap"
DRY=0; PURGE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --purge) PURGE=1 ;;
        *) echo "Pilihan tidak dikenal: $arg"; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
run() { if [ "$DRY" -eq 1 ]; then say "  [dry-run] $*"; else "$@"; fi; }

if [ "$DRY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    say "✗ Perlu sudo: sudo $0"; exit 1
fi

# 1. Limit off, using the installed CLI or the built one.
CLI="$CLI_DEST"; [ -x "$CLI" ] || CLI="$ROOT/.build/release/chargecap"
if [ -x "$CLI" ]; then
    say "1. Mematikan batas pengisian"
    run "$CLI" off
else
    say "1. (chargecap tidak ditemukan; lewati. Pastikan sendiri: bfF0 harus 00)"
fi

# 2. Stop the daemon.
say "2. Menghentikan daemon"
if [ "$DRY" -eq 1 ]; then
    say "  [dry-run] launchctl bootout system/$LABEL"
else
    launchctl bootout "system/$LABEL" 2>/dev/null || true
fi

# 3. Files.
say "3. Menghapus file"
run rm -f "$PLIST" "$CLI_DEST"
run rm -rf "$LIBEXEC"
run rm -f /var/log/chargecap-daemon.out /var/log/chargecap-daemon.err
if [ "$PURGE" -eq 1 ]; then
    run rm -rf "$CONFIG_DIR"
    run rm -f /var/log/chargecap.log
else
    say "  config dan log dibiarkan ($CONFIG_DIR, /var/log/chargecap.log); hapus dengan --purge"
fi

say ""
say "Selesai. Mac mengisi seperti biasa (tanpa batas)."
