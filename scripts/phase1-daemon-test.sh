#!/bin/bash
# Phase 1 check on the real Mac (needs sudo): the daemon must put bfF0 back when the firmware clears it.
#   sudo scripts/phase1-daemon-test.sh
# Starts chargecapd, clears bfF0 behind its back, waits for the one-minute timer, shows the result,
# then switches the limit off again (chargecap off).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/.build/release"
[ "$(id -u)" -eq 0 ] || { echo "Perlu sudo: sudo $0"; exit 1; }
[ -x "$B/chargecapd" ] || { echo "Build dulu: swift build -c release"; exit 1; }

cleanup() { kill "$DAEMON" 2>/dev/null; sleep 1; echo "---- dimatikan"; "$B/chargecap" off; "$B/chargecap" status; }
"$B/chargecapd" &
DAEMON=$!
trap cleanup EXIT

sleep 4
echo "---- sebelum: $("$B/smc-rw" read bfF0 bfD0 bfE0 | tr '\n' ' ')"
"$B/smc-rw" write bfF0 00
echo "---- bfF0 dimatikan paksa. Menunggu daemon (maks 75 detik)..."
for i in $(seq 1 75); do
    sleep 1
    if [ "$("$B/smc-rw" read bfF0 | cut -d' ' -f4)" = "02" ]; then
        echo "---- LULUS: daemon mengembalikan bfF0=02 setelah ${i} detik"
        break
    fi
    [ "$i" -eq 75 ] && echo "---- GAGAL: bfF0 tidak dikembalikan"
done
echo "---- status:"; "$B/chargecap" status
echo "---- log:"; "$B/chargecap" logs 8
