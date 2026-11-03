#!/bin/bash
# Phase 0b — write the firmware charge limit (bfD0 / bfE0) ourselves and check the Mac obeys.
#
#   sudo ./scripts/phase0-write.sh                  main test: stop, resume, optional sleep test
#   sudo ./scripts/phase0-write.sh --reboot-test    set a limit and KEEP it, then restart the Mac
#        ./scripts/phase0-write.sh --after-reboot   (no sudo) check whether the limit survived the restart
#   sudo ./scripts/phase0-write.sh --restore        put the values back to what they were before the tests
#        ./scripts/phase0-write.sh --preflight      only check that everything is ready
#
# bfD0 = stop charging at this %, bfE0 = start charging again at this %.
# Both are ui32 little-endian: 80% is "50000000", 100% is "64000000".
# The main test always restores the original values on exit, also after Ctrl+C.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMC="$ROOT/.build/release/smc-rw"
STATE="$ROOT/logs/.phase0-write-state"      # remembers original values and the reboot-test log dir
MODE="${1:-main}"

# ---------- helpers ----------

say() { printf '%s\n' "$*" | tee -a "$LOG"; }

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'; }

ioreg_value() { ioreg -rn AppleSmartBattery | sed -nE "s/^ *\"$1\" = (.*)$/\1/p" | head -1; }

charger_value() { ioreg -rn AppleSmartBattery | grep -o "\"$1\"=[0-9]*" | head -1 | cut -d= -f2; }

smc_hex() { "$SMC" read "$1" 2>/dev/null | cut -d' ' -f4; }

hex_to_pct() { printf '%d' "0x${1:0:2}"; }       # first byte of a little-endian ui32

pct_to_hex() { printf '%02x000000' "$1"; }

battery_state() {
    PCT="$(ioreg_value CurrentCapacity)"
    CHARGING="$(ioreg_value IsCharging)"
    EXTERNAL="$(ioreg_value ExternalConnected)"
    NOTCHG="$(charger_value NotChargingReason)"
    BFD0="$(smc_hex bfD0)"; BFE0="$(smc_hex bfE0)"; BFF0="$(smc_hex bfF0)"
    PMSET="$(pmset -g batt | tail -1 | sed -E 's/^ *//')"
}

record() {  # record STEP RESULT NOTE
    battery_state
    say "[$(date +%H:%M:%S)] $1 | $2 | baterai ${PCT}% | mengisi=$CHARGING | charger=$EXTERNAL | bfF0=$BFF0 bfD0=$(hex_to_pct "$BFD0")% bfE0=$(hex_to_pct "$BFE0")% | NotChargingReason=$NOTCHG"
    [ -n "${3:-}" ] && say "           catatan: $3"
    printf '{"time":"%s","step":"%s","result":"%s","pct":%s,"charging":"%s","external":"%s","bfD0":"%s","bfE0":"%s","not_charging_reason":"%s","pmset":"%s","note":"%s"}\n' \
        "$(date +%Y-%m-%dT%H:%M:%S%z)" "$(json_escape "$1")" "$2" "${PCT:-null}" "$CHARGING" "$EXTERNAL" \
        "$BFD0" "$BFE0" "$NOTCHG" "$(json_escape "$PMSET")" "$(json_escape "${3:-}")" >> "$JSONL"
}

set_limit() {  # set_limit STOP_PCT RESUME_PCT -> 0 if every write read back correctly
    # Order matters: the firmware rejects a config where stop < resume (SMC error 0x89, "bad argument")
    # and then clears the mode flag bfF0. So lower resume first when lowering, raise stop first when raising,
    # switch the mode on last and off first.
    local stop="$1" resume="$2" mode out rc=0 key hex cur_resume order
    if [ "$stop" -ge 100 ]; then mode="00"; else mode="02"; fi
    cur_resume="$(hex_to_pct "$(smc_hex bfE0)")"
    if [ "$resume" -lt "$cur_resume" ]; then
        order="bfE0 bfD0"
    else
        order="bfD0 bfE0"
    fi
    if [ "$mode" = "00" ]; then order="bfF0 $order"; else order="$order bfF0"; fi
    for key in $order; do
        case "$key" in
            bfF0) hex="$mode" ;;
            bfD0) hex="$(pct_to_hex "$stop")" ;;
            bfE0) hex="$(pct_to_hex "$resume")" ;;
        esac
        out="$("$SMC" write "$key" "$hex" 2>&1)" || rc=1
        if [[ "$out" == \{* ]]; then
            printf '{"time":"%s","write":%s}\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$out" >> "$JSONL"
        else
            printf '{"time":"%s","write":"%s"}\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$(json_escape "$out")" >> "$JSONL"
        fi
        say "           tulis $key = $hex → $out"
    done
    return "$rc"
}

wait_for_charging() {  # wait_for_charging Yes|No SECONDS
    local want="$1" limit="$2" waited=0
    while [ "$waited" -lt "$limit" ]; do
        [ "$(ioreg_value IsCharging)" = "$want" ] && return 0
        sleep 5; waited=$((waited + 5))
    done
    return 1
}

new_logdir() {
    LOGDIR="$ROOT/logs/phase0-write-$(date +%Y-%m-%dT%H-%M-%S)-$1"
    mkdir -p "$LOGDIR"
    LOG="$LOGDIR/summary.log"; JSONL="$LOGDIR/steps.jsonl"
}

give_logs_back() {  # files created under sudo belong to root; hand them back to the real user
    [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER" "$ROOT/logs" 2>/dev/null
}

save_original() {  # keep the very first original values; later runs must not overwrite them
    if [ ! -f "$STATE" ]; then
        printf 'ORIG_BFD0=%s\nORIG_BFE0=%s\nORIG_BFF0=%s\n' "$(smc_hex bfD0)" "$(smc_hex bfE0)" "$(smc_hex bfF0)" > "$STATE"
    fi
    # shellcheck disable=SC1090
    . "$STATE"
}

restore_original() {
    save_original
    say ""
    say "Mengembalikan nilai awal: bfF0=${ORIG_BFF0:-00} bfD0=$(hex_to_pct "$ORIG_BFD0")% bfE0=$(hex_to_pct "$ORIG_BFE0")%"
    "$SMC" write bfD0 "$ORIG_BFD0" >> "$JSONL" 2>&1
    "$SMC" write bfE0 "$ORIG_BFE0" >> "$JSONL" 2>&1
    "$SMC" write bfF0 "${ORIG_BFF0:-00}" >> "$JSONL" 2>&1
    record "pemulihan" "$([ "$(smc_hex bfD0)" = "$ORIG_BFD0" ] && [ "$(smc_hex bfE0)" = "$ORIG_BFE0" ] && [ "$(smc_hex bfF0)" = "${ORIG_BFF0:-00}" ] && echo LULUS || echo GAGAL)" "nilai dikembalikan ke kondisi sebelum uji"
}

pause() { printf '\n%s\n→ Tekan Enter kalau sudah... ' "$1"; read -r _; echo; }

# ---------- preflight ----------

preflight() {  # preflight NEED_ROOT(yes|no)
    local ok=0 pct
    [ -x "$SMC" ] || { echo "✗ smc-rw belum di-build. Jalankan: swift build -c release"; ok=1; }
    if [ "$1" = yes ] && [ "$(id -u)" -ne 0 ]; then echo "✗ Perlu sudo: sudo $0 ${MODE/main/}"; ok=1; fi
    if pgrep -xq AlDente; then echo "✗ AlDente masih berjalan. Tutup dulu (ikon menu bar → Quit) supaya tidak saling menimpa."; ok=1; fi
    [ "$(ioreg_value ExternalConnected)" = "Yes" ] || { echo "✗ Charger belum terpasang."; ok=1; }
    pct="$(ioreg_value CurrentCapacity)"
    if [ "${pct:-0}" -lt 20 ] || [ "${pct:-100}" -ge 95 ]; then echo "✗ Baterai ${pct}% — uji butuh 20–94%."; ok=1; fi
    smc_hex bfD0 >/dev/null && [ -n "$(smc_hex bfD0)" ] || { echo "✗ Tidak bisa membaca bfD0."; ok=1; }
    [ "$ok" -eq 0 ] && echo "✓ Siap: AlDente tertutup, charger terpasang, baterai ${pct}%, bfD0=$(hex_to_pct "$(smc_hex bfD0)")% bfE0=$(hex_to_pct "$(smc_hex bfE0)")%."
    return "$ok"
}

header() {
    say "ChargeCap Fase 0b — $1 ($(date +%Y-%m-%dT%H:%M:%S))"
    say "Mac: $(sysctl -n hw.model), macOS $(sw_vers -productVersion)"
    say "Nilai awal (sebelum semua uji): bfF0=${ORIG_BFF0:-00} bfD0=$(hex_to_pct "$ORIG_BFD0")% bfE0=$(hex_to_pct "$ORIG_BFE0")%"
    say ""
}

# ---------- modes ----------

case "$MODE" in

--preflight)
    preflight yes; exit $? ;;

--restore)
    [ "$(id -u)" -eq 0 ] || { echo "✗ Perlu sudo: sudo $0 --restore"; exit 1; }
    new_logdir restore; save_original; header "pemulihan manual"
    restore_original; rm -f "$STATE"; give_logs_back; exit 0 ;;

--after-reboot)
    [ -f "$STATE" ] || { echo "✗ Belum ada uji restart. Jalankan dulu: sudo $0 --reboot-test"; exit 1; }
    . "$STATE"
    [ -n "${REBOOT_LOGDIR:-}" ] || { echo "✗ Uji restart belum dimulai."; exit 1; }
    LOGDIR="$REBOOT_LOGDIR"; LOG="$LOGDIR/summary.log"; JSONL="$LOGDIR/steps.jsonl"
    battery_state
    if [ "$BFD0" = "$REBOOT_BFD0" ] && [ "$BFE0" = "$REBOOT_BFE0" ]; then
        record "R2. setelah restart" "LULUS" "batas firmware BERTAHAN setelah restart"
    else
        record "R2. setelah restart" "INFO" "batas firmware BERUBAH setelah restart (dulu bfD0=$(hex_to_pct "$REBOOT_BFD0")% bfE0=$(hex_to_pct "$REBOOT_BFE0")%) — daemon harus menulis ulang saat start"
    fi
    say "           boot terakhir: $(sysctl -n kern.boottime | sed -E 's/.*} //')"
    say ""
    say "Langkah terakhir: sudo $0 --restore   (mengembalikan nilai awal)"
    exit 0 ;;

--reboot-test)
    preflight yes || exit 1
    new_logdir reboot; save_original; header "uji restart"
    battery_state
    stop=$((PCT)); resume=$((PCT - 5))
    set_limit "$stop" "$resume"
    printf 'REBOOT_LOGDIR=%s\nREBOOT_BFD0=%s\nREBOOT_BFE0=%s\n' "$LOGDIR" "$(pct_to_hex "$stop")" "$(pct_to_hex "$resume")" >> "$STATE"
    record "R1. sebelum restart" "INFO" "batas diset ke ${stop}%/${resume}% dan SENGAJA dibiarkan"
    say ""
    say "Sekarang restart Mac (Apple menu → Restart). Setelah login, JANGAN buka AlDente, lalu jalankan:"
    say "    cd $ROOT && ./scripts/phase0-write.sh --after-reboot"
    give_logs_back; exit 0 ;;

main) ;;

*)
    echo "Pilihan tidak dikenal: $MODE"; exit 2 ;;
esac

# ---------- main test ----------

preflight yes || exit 1
new_logdir main; save_original; header "uji tulis bfD0/bfE0"
finish_main() {
    restore_original
    # Forget the saved originals unless a restart test is still waiting for --after-reboot.
    grep -q '^REBOOT_LOGDIR=' "$STATE" 2>/dev/null || rm -f "$STATE"
    give_logs_back
    say ""
    say "Selesai. Semua file ada di: $LOGDIR"
}
trap finish_main EXIT
trap 'say ""; say "Dihentikan (Ctrl+C)."; exit 130' INT TERM

# 1. baseline: no limit, battery must charge
set_limit 100 99
if wait_for_charging Yes 90; then
    record "1. batas 100%" "LULUS" "baterai mengisi"
else
    record "1. batas 100%" "GAGAL" "baterai tidak mengisi dalam 90 detik"
fi

# 2. our own limit at the current %, charging must stop
battery_state
stop=$((PCT)); resume=$((PCT - 5))
set_limit "$stop" "$resume" || say "           (ada tulisan yang gagal, tes tetap menunggu)"
if wait_for_charging No 240; then
    record "2. batas ${stop}%/${resume}%" "LULUS" "pengisian BERHENTI karena tulisan kita (bfF0=02)"
else
    record "2. batas ${stop}%/${resume}%" "GAGAL" "pengisian tidak berhenti dalam 240 detik"
fi
sleep 30
record "2b. 30 detik kemudian" "$([ "$(ioreg_value IsCharging)" = No ] && echo LULUS || echo GAGAL)" "pengisian tetap berhenti"

# 3. lift the limit, charging must resume
set_limit 100 99 || say "           (ada tulisan yang gagal, tes tetap menunggu)"
if wait_for_charging Yes 120; then
    record "3. batas 100% lagi" "LULUS" "pengisian JALAN lagi"
else
    record "3. batas 100% lagi" "GAGAL" "pengisian tidak jalan lagi dalam 120 detik"
fi

# 4. optional sleep test
printf '\nUji tidur? Tutup layar ±10 menit lalu buka lagi. [y/N] '
read -r answer
if [ "$answer" = y ] || [ "$answer" = Y ]; then
    battery_state
    stop=$((PCT)); resume=$((PCT - 5))
    set_limit "$stop" "$resume"
    wait_for_charging No 240
    record "4a. sebelum tidur" "INFO" "batas ${stop}%/${resume}%"
    before="$(date '+%Y-%m-%d %H:%M:%S')"
    pause "Tutup layar Mac sekarang, tunggu ±10 menit, buka lagi dan login."
    battery_state
    if [ "$(hex_to_pct "$BFD0")" -eq "$stop" ] && [ "$PCT" -le $((stop + 1)) ]; then
        record "4b. setelah bangun" "LULUS" "batas bertahan saat tidur, baterai tidak lewat batas"
    else
        record "4b. setelah bangun" "GAGAL" "batas berubah atau baterai naik melewati ${stop}%"
    fi
    pmset -g log | awk -v t="$before" '$0 >= t' | grep -E ' (Sleep|Wake|DarkWake) ' | tail -10 > "$LOGDIR/sleep-wake.txt"
    say "           riwayat tidur/bangun: $(wc -l < "$LOGDIR/sleep-wake.txt" | tr -d ' ') baris → sleep-wake.txt"
else
    say "Uji tidur dilewati."
fi
