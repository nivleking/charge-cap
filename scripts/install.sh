#!/bin/bash
# Installs ChargeCap as a LaunchDaemon: the daemon starts at boot and keeps the charge limit in place.
#
#   sudo scripts/install.sh              install (or update) and start
#        scripts/install.sh --dry-run    show what would happen and check the plist; changes nothing, no sudo
#
# What it puts on the Mac (all owned by root, so only root can change what the daemon runs):
#   /usr/local/libexec/chargecap/chargecapd           the daemon
#   /usr/local/bin/chargecap                          the command line tool
#   /Library/LaunchDaemons/dev.kelvin.chargecap.plist starts the daemon at boot, restarts it if it dies
#   /Library/Application Support/ChargeCap/           config.json (created "off" if missing)
# The limit stays OFF until you run: sudo chargecap limit 80
# Undo everything with: sudo scripts/uninstall.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release"
LABEL="dev.kelvin.chargecap"
LIBEXEC="/usr/local/libexec/chargecap"
CLI_DEST="/usr/local/bin/chargecap"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
CONFIG_DIR="/Library/Application Support/ChargeCap"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say() { printf '%s\n' "$*"; }
run() { if [ "$DRY" -eq 1 ]; then say "  [dry-run] $*"; else "$@"; fi; }

write_plist() {  # write_plist DEST
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$LIBEXEC/chargecapd</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>/var/log/chargecap-daemon.err</string>
  <key>StandardOutPath</key><string>/var/log/chargecap-daemon.out</string>
</dict>
</plist>
PLIST
}

# ---------- checks ----------

if [ "$DRY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    say "✗ Perlu sudo: sudo $0"; exit 1
fi

# Build as the normal user (a root-owned .build would be a nuisance), only when something is missing.
if [ ! -x "$BIN/chargecapd" ] || [ ! -x "$BIN/chargecap" ]; then
    say "Membangun versi release..."
    if [ "$DRY" -eq 1 ]; then
        say "  [dry-run] swift build -c release"
    elif [ -n "${SUDO_USER:-}" ]; then
        (cd "$ROOT" && sudo -u "$SUDO_USER" swift build -c release) || { say "✗ Build gagal"; exit 1; }
    else
        say "✗ Build dulu sebagai user biasa: swift build -c release"; exit 1
    fi
fi

if pgrep -xq AlDente; then
    say "✗ AlDente sedang berjalan. Tutup dulu (Quit), supaya dua program tidak saling menimpa kunci SMC."
    [ "$DRY" -eq 1 ] || exit 1
fi

# ---------- plist ----------

TMP_PLIST="$(mktemp -t chargecap-plist)"
write_plist "$TMP_PLIST"
if plutil -lint "$TMP_PLIST" >/dev/null; then
    say "✓ plist valid"
else
    say "✗ plist rusak"; rm -f "$TMP_PLIST"; exit 1
fi

# ---------- install ----------

say "Memasang ChargeCap..."
if [ "$DRY" -eq 0 ] && launchctl print "system/$LABEL" >/dev/null 2>&1; then
    say "  daemon lama ditemukan, dihentikan dulu"
    launchctl bootout "system/$LABEL" 2>/dev/null
    sleep 1
fi

run install -d -m 755 -o root -g wheel "$LIBEXEC"
run install -m 755 -o root -g wheel "$BIN/chargecapd" "$LIBEXEC/chargecapd"
run install -d -m 755 -o root -g wheel "$(dirname "$CLI_DEST")"
run install -m 755 -o root -g wheel "$BIN/chargecap" "$CLI_DEST"
run install -d -m 755 -o root -g wheel "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.json" ]; then
    if [ "$DRY" -eq 1 ]; then
        say "  [dry-run] buat $CONFIG_DIR/config.json (batas mati)"
    else
        printf '{\n  "enabled" : false,\n  "gap" : 5,\n  "limit" : 80\n}\n' > "$CONFIG_DIR/config.json"
        chown root:wheel "$CONFIG_DIR/config.json"; chmod 644 "$CONFIG_DIR/config.json"
    fi
else
    say "  config.json sudah ada, tidak diubah"
fi
if [ "$DRY" -eq 1 ]; then
    say "  [dry-run] pasang $PLIST (root:wheel 644)"
else
    install -m 644 -o root -g wheel "$TMP_PLIST" "$PLIST"
fi
rm -f "$TMP_PLIST"

run launchctl bootstrap system "$PLIST"
run launchctl kickstart -k "system/$LABEL"

# ---------- verify ----------

if [ "$DRY" -eq 1 ]; then
    say ""
    say "Dry-run selesai: tidak ada yang diubah."
    exit 0
fi

sleep 3
if launchctl print "system/$LABEL" 2>/dev/null | grep -q "state = running"; then
    say "✓ Daemon berjalan."
else
    say "✗ Daemon tidak terlihat berjalan. Cek: launchctl print system/$LABEL ; chargecap logs ; /var/log/chargecap-daemon.err"
    exit 1
fi
say ""
chargecap logs 3 2>/dev/null
say ""
say "Selesai. Batas masih MATI. Nyalakan dengan: sudo chargecap limit 80"
say "Status: chargecap status      Copot: sudo $ROOT/scripts/uninstall.sh"
