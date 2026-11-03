#!/bin/bash
# Phase 0a — watch AlDente stop charging and find which SMC key it changes.
#
# Read-only: this script never writes to the SMC and does not need sudo.
# It snapshots every SMC key while AlDente lets the battery charge and again
# after AlDente stops it, then lists the keys that changed.
#
# Usage:  ./scripts/phase0-observe.sh            (interactive run)
#         ./scripts/phase0-observe.sh --preflight (only check that everything is ready)

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMC="$ROOT/.build/release/smc-rw"
STAMP="$(date +%Y-%m-%dT%H-%M-%S)"
LOGDIR="$ROOT/logs/phase0-observe-$STAMP"
LOG="$LOGDIR/summary.log"
JSONL="$LOGDIR/steps.jsonl"

# ---------- helpers ----------

say() { printf '%s\n' "$*" | tee -a "$LOG"; }

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'; }

ioreg_value() {  # ioreg_value NAME -> top-level AppleSmartBattery value
    ioreg -rn AppleSmartBattery | sed -nE "s/^ *\"$1\" = (.*)$/\1/p" | head -1
}

charger_value() {  # charger_value NAME -> value inside the ChargerData dictionary
    ioreg -rn AppleSmartBattery | grep -o "\"$1\"=[0-9]*" | head -1 | cut -d= -f2
}

battery_state() {  # sets PCT CHARGING EXTERNAL INHIBIT NOTCHG PMSET
    PCT="$(ioreg_value CurrentCapacity)"
    CHARGING="$(ioreg_value IsCharging)"
    EXTERNAL="$(ioreg_value ExternalConnected)"
    INHIBIT="$(charger_value ChargerInhibitReason)"
    NOTCHG="$(charger_value NotChargingReason)"
    PMSET="$(pmset -g batt | tail -1 | sed -E 's/^ *//')"
}

record() {  # record STEP RESULT NOTE
    battery_state
    say "[$(date +%H:%M:%S)] $1 | $2 | baterai ${PCT}% | mengisi=$CHARGING | charger=$EXTERNAL | ChargerInhibitReason=$INHIBIT | NotChargingReason=$NOTCHG"
    [ -n "${3:-}" ] && say "           catatan: $3"
    printf '{"time":"%s","step":"%s","result":"%s","pct":%s,"charging":"%s","external":"%s","charger_inhibit_reason":"%s","not_charging_reason":"%s","pmset":"%s","note":"%s"}\n' \
        "$(date +%Y-%m-%dT%H:%M:%S%z)" "$(json_escape "$1")" "$2" "${PCT:-null}" "$CHARGING" "$EXTERNAL" \
        "$INHIBIT" "$NOTCHG" "$(json_escape "$PMSET")" "$(json_escape "${3:-}")" >> "$JSONL"
}

wait_for_charging() {  # wait_for_charging Yes|No SECONDS -> 0 when IsCharging reaches the wanted value
    local want="$1" limit="$2" waited=0
    while [ "$waited" -lt "$limit" ]; do
        [ "$(ioreg_value IsCharging)" = "$want" ] && return 0
        sleep 5; waited=$((waited + 5))
    done
    return 1
}

snapshot() {  # snapshot NAME -> logs every SMC key value into NAME.txt
    "$SMC" list > "$LOGDIR/$1.txt" 2>&1
    say "           snapshot SMC: $(wc -l < "$LOGDIR/$1.txt" | tr -d ' ') tombol → $1.txt"
}

pause() { printf '\n%s\n→ Tekan Enter kalau sudah... ' "$1"; read -r _; echo; }

# ---------- preflight ----------

preflight() {
    local ok=0
    [ -x "$SMC" ] || { echo "✗ smc-rw belum di-build. Jalankan: swift build -c release"; ok=1; }
    [ "$(id -u)" -ne 0 ] || { echo "✗ Jangan pakai sudo; skrip ini hanya membaca."; ok=1; }
    pgrep -xq AlDente || { echo "✗ AlDente tidak berjalan. Buka AlDente dulu (skrip ini mengamati AlDente)."; ok=1; }
    [ "$(ioreg_value ExternalConnected)" = "Yes" ] || { echo "✗ Charger belum terpasang."; ok=1; }
    local pct; pct="$(ioreg_value CurrentCapacity)"
    if [ "${pct:-100}" -ge 95 ]; then echo "✗ Baterai ${pct}% — terlalu penuh untuk melihat pengisian. Tunggu sampai di bawah 95%."; ok=1; fi
    "$SMC" read CHIE >/dev/null 2>&1 || { echo "✗ smc-rw tidak bisa membaca SMC."; ok=1; }
    [ "$ok" -eq 0 ] && echo "✓ Siap: AlDente jalan, charger terpasang, baterai ${pct}%."
    return "$ok"
}

if [ "${1:-}" = "--preflight" ]; then preflight; exit $?; fi
preflight || exit 1

mkdir -p "$LOGDIR"
say "ChargeCap Fase 0a — mengamati AlDente ($STAMP)"
say "Mac: $(sysctl -n hw.model), macOS $(sw_vers -productVersion), AlDente $(defaults read /Applications/AlDente.app/Contents/Info CFBundleShortVersionString 2>/dev/null)"
say "Skrip ini hanya MEMBACA. Tidak ada nilai SMC yang diubah."
say ""

# ---------- step 1: charging allowed ----------

pause "LANGKAH 1: Di AlDente, geser batas pengisian ke 100% supaya baterai MENGISI."
if wait_for_charging Yes 90; then
    record "1. AlDente batas 100%" "LULUS" "baterai mengisi"
else
    record "1. AlDente batas 100%" "GAGAL" "baterai tidak mulai mengisi dalam 90 detik"
fi
snapshot "a-mengisi-1"
sleep 15
snapshot "a-mengisi-2"   # second snapshot while charging: keys that differ here are just noisy sensors

# ---------- step 2: AlDente stops charging ----------

battery_state
pause "LANGKAH 2: Di AlDente, geser batas ke angka DI BAWAH ${PCT}% (misalnya 50%) supaya AlDente MENGHENTIKAN pengisian."
if wait_for_charging No 120; then
    record "2. AlDente batas di bawah %" "LULUS" "pengisian berhenti"
else
    record "2. AlDente batas di bawah %" "GAGAL" "pengisian tidak berhenti dalam 120 detik"
fi
snapshot "b-berhenti"

# ---------- step 3: back to charging ----------

pause "LANGKAH 3: Kembalikan batas AlDente ke 100% supaya MENGISI lagi."
if wait_for_charging Yes 90; then
    record "3. AlDente kembali 100%" "LULUS" "baterai mengisi lagi"
else
    record "3. AlDente kembali 100%" "GAGAL" "baterai tidak mengisi lagi dalam 90 detik"
fi
snapshot "c-mengisi-lagi"

# ---------- analysis ----------

say ""
say "=== Tombol SMC yang berubah saat AlDente menghentikan pengisian ==="
# Compare "KEY HEX" pairs across snapshots. Keys that changed between the two
# charging snapshots are sensor noise (temperatures, currents) and are ignored.
awk '
    FNR == 1 { file++ }
    $2 == "?" { next }                      # unreadable keys
    { value[file, $1] = $4; type[$1] = $2; seen[$1] = 1 }
    END {
        for (k in seen) {
            if (value[1, k] != value[2, k]) { print k > noisy; continue }
            if (value[2, k] != value[3, k]) print k, type[k], value[2, k], value[3, k], value[4, k]
        }
    }
' noisy="$LOGDIR/noisy-keys.txt" \
    "$LOGDIR/a-mengisi-1.txt" "$LOGDIR/a-mengisi-2.txt" "$LOGDIR/b-berhenti.txt" "$LOGDIR/c-mengisi-lagi.txt" \
    | sort > "$LOGDIR/candidates-3way.txt"
touch "$LOGDIR/noisy-keys.txt"
say "(diabaikan $(wc -l < "$LOGDIR/noisy-keys.txt" | tr -d ' ') tombol sensor yang memang naik-turun; daftar di noisy-keys.txt)"

if [ -s "$LOGDIR/candidates-3way.txt" ]; then
    say "tombol | tipe | saat mengisi | saat berhenti | setelah mengisi lagi"
    while read -r key ktype charging stopped again; do
        # Measurements are stored as floats; a control switch is an integer/flag that
        # flips when charging stops and flips back when it resumes.
        mark=""
        if [ "$charging" = "$again" ]; then
            case "$ktype" in
                flt|fp*|sp*) mark="   (sensor angka, kemungkinan bukan tombol kendali)" ;;
                *) mark="   ← kembali ke nilai awal (KANDIDAT KUAT)" ;;
            esac
        fi
        key="$key | $ktype"
        say "$key | $charging | $stopped | $again$mark"
    done < "$LOGDIR/candidates-3way.txt"
else
    say "Tidak ada tombol yang berubah (selain sensor yang memang naik-turun)."
    say "Artinya AlDente kemungkinan TIDAK memakai SMC di Mac ini, melainkan mekanisme macOS lain."
fi
say ""
say "Selesai. Semua file ada di: $LOGDIR"
