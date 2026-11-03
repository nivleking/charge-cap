# ChargeCap

Pembatas pengisian baterai pribadi (pengganti AlDente) untuk MacBookPro18,1 (M1 Pro) macOS 15.8.1.
Memakai batas pengisian **di firmware** lewat tiga kunci SMC (`bfF0`, `bfD0`, `bfE0`), jadi pengisian
dihentikan oleh Mac sendiri. Rencana dan temuan: [PLAN.md](PLAN.md).

```sh
swift build -c release
swift test                                  # logika memakai SMC palsu, tidak menyentuh perangkat keras

.build/release/chargecap status             # baterai, kunci SMC, config (tanpa sudo)
sudo .build/release/chargecap limit 80      # set batas 80% dan terapkan sekarang
sudo .build/release/chargecap off           # matikan batas (tombol darurat)
sudo .build/release/chargecap apply         # samakan kunci dengan config.json sekali
.build/release/chargecap logs
sudo .build/release/chargecapd              # daemon di foreground (untuk uji)

scripts/install.sh --dry-run                # lihat apa yang akan dipasang (tanpa sudo, tidak mengubah apa pun)
sudo scripts/install.sh                     # pasang LaunchDaemon: jalan sendiri sejak boot, batas tetap MATI
sudo scripts/uninstall.sh [--purge]         # copot, batas dimatikan dulu
```

Config: `/Library/Application Support/ChargeCap/config.json` (`CHARGECAP_DIR` untuk mengganti, `CHARGECAP_LOG`
untuk log). Bawaan: **mati**. `smc-rw` adalah alat Fase 0 untuk membaca kunci SMC.
