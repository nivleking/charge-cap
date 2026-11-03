# ChargeCap

Pembatas pengisian baterai pribadi (pengganti AlDente) untuk MacBookPro18,1 (M1 Pro) macOS 15.8.1.
Memakai batas pengisian **di firmware** lewat tiga kunci SMC (`bfF0`, `bfD0`, `bfE0`), jadi pengisian
dihentikan oleh Mac sendiri. Rencana dan temuan: [PLAN.md](PLAN.md).

```sh
swift build -c release
swift test                                  # logika memakai SMC palsu, tidak menyentuh perangkat keras

.build/release/chargecap status             # baterai, kunci SMC, config (tanpa sudo)
chargecap limit 80                          # set batas 80% (daemon menerapkan seketika; tanpa sudo)
sudo chargecap off                          # matikan batas (tombol darurat, jalan walau daemon mati)
chargecap gap 5                             # mulai mengisi lagi 5 poin di bawah batas
chargecap heat 35                           # berhenti mengisi di 35 °C ('heat off' mematikan)
chargecap topup                             # isi sampai 100% sekali, lalu batas kembali
sudo .build/release/chargecap apply         # samakan kunci dengan config.json sekali
.build/release/chargecap logs
.build/release/chargecap report             # tertinggi hari ini vs batas, ringkasan log 24 jam
sudo .build/release/chargecapd              # daemon di foreground (untuk uji)

scripts/install.sh --dry-run                # lihat apa yang akan dipasang (tanpa sudo, tidak mengubah apa pun)
sudo scripts/install.sh                     # pasang LaunchDaemon: jalan sendiri sejak boot, batas tetap MATI
sudo scripts/uninstall.sh [--purge]         # copot, batas dimatikan dulu
```

Config: `/Library/Application Support/ChargeCap/config.json` (`CHARGECAP_DIR` untuk mengganti, `CHARGECAP_LOG`
untuk log). Bawaan: **mati**. `smc-rw` adalah alat Fase 0 untuk membaca kunci SMC.

Aplikasi menu bar: `scripts/make-app.sh --install` (ChargeCap.app), atau modul ChargeCap di KTools.
