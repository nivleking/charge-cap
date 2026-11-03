# ChargeCap — rencana aplikasi pembatas pengisian baterai

> Nama kerja: **ChargeCap**. Boleh diganti.
> Dibuat 23 Okt 2026 dari hasil analisis AlDente 1.39.4 dengan REA (Hopper + Ghidra).

## 1. Tujuan

Aplikasi pribadi untuk MacBook kamu yang **menahan baterai di batas tertentu (misalnya 80%) dengan andal**,
termasuk saat Mac tidur. Ini pengganti AlDente, yang terbukti tembus ke 100%.

Bukan tujuan (setidaknya di versi awal): dijual/didistribusikan, fitur lengkap seperti AlDente Pro.

## 2. Mac target

| | |
|---|---|
| Mac | MacBookPro18,1 (MacBook Pro 16" 2021, Apple M1 Pro) |
| macOS | 15.8.1 (24H32) |
| Baterai | 418 siklus, kapasitas ~85% dari desain (7360 / 8694 mAh) |
| Toolchain | Swift 6.1.2 lewat Command Line Tools, SDK macOS 15.5. **Xcode tidak terpasang dan tidak wajib.** |

Bukti masalah AlDente: `ioreg -rn AppleSmartBattery` mencatat `DailyMaxSoc = 100` pada 23 Okt 2026,
artinya baterai memang sempat penuh 100% hari itu walau AlDente terpasang.

## 2b. Temuan 24 Okt 2026 (mengubah rencana)

- **`CHTE` tidak ada di Mac ini.** `smc-rw list CH` (2179 tombol SMC terbaca) tidak menemukan `CHTE`,
  `CH0B`, `CH0C`, maupun `CH0I`. Yang ada: `CHIE` (hex_, 1 byte, nilai `00`), plus tombol lain seperti
  `CH0J`, `CHIC`, `CHIB`, `CHIL`, `CHIO`, `CHIS`. Di kode AlDente, cabang `CHTE` hanya dipakai untuk model
  tertentu (flag `mbModel`), jadi di M1 Pro + macOS 15.8.1 AlDente memakai cara lain yang belum kita ketahui.
- **Petunjuk bug AlDente** (dari `defaults read com.apphousekitchen.aldente-pro`):
  - `launchAtLogin = 0` → AlDente tidak jalan otomatis setelah restart. Kalau lupa dibuka, tidak ada yang
    membatasi pengisian → baterai bisa sampai 100%. **Kandidat kuat penyebab bug.**
  - `useTahoeNativeLimit = 1` padahal Mac ini macOS 15, bukan Tahoe (26).
- **Hasil Fase 0a pertama** (`logs/phase0-observe-2026-10-24T08-45-55`): AlDente yang terpasang ternyata
  **1.38.1** (helper bertanda tangan 13 Apr 2026, berjalan). Saat batas diturunkan di bawah 73%, AlDente
  **tidak menghentikan pengisian** selama 120 detik — bug terekam langsung. Tidak ada tombol kendali SMC yang
  berubah; yang berubah hanya sensor (suhu `T…`, baterai `B…`, daya/arus `IP1b`/`PP1b`/`IR4b`/`PR4b`).
- **Hasil Fase 0a kedua** (`logs/phase0-observe-2026-10-24T08-52-35`, AlDente **1.39.4**): pengisian
  **berhenti** dalam ±90 detik. Tombol yang berubah lalu kembali:

  | Tombol | Tipe | Mengisi (batas 100%) | Berhenti | Mengisi lagi | Peran |
  |---|---|---|---|---|---|
  | **`bfD0`** | ui32 | `64000000` (100) | `4d000000` (77) | `64000000` | **Batas atas: berhenti mengisi di %** — ditulis AlDente |
  | **`bfE0`** | ui32 | `63000000` (99) | `4c000000` (76) | `63000000` | **Batas bawah: mulai mengisi lagi di %** — ditulis AlDente |
  | `CHSC` | ui8 | `01` | `00` | `01` | status: sedang mengisi (akibat) |
  | `CIPC` | ui32 | `1` | `0` | `1` | status: pengisian berjalan (akibat) |
  | `CHNC` | hex_ 8 | `0` | bit 55 | `0` | alasan tidak mengisi = `NotChargingReason` 36028797018963968 (akibat) |
  | `ACLC` | ui8 | `04` | `02` | `04` | lampu MagSafe oranye → hijau (akibat) |

  Pada percobaan AlDente 1.38.1, `bfD0`/`bfE0` tetap `00000000` → versi lama **tidak pernah menulis tombol
  ini**, itulah sebabnya pengisian tidak berhenti. Nilai disimpan **little-endian** (byte pertama = persen).
- **Kesimpulan:** Mac ini punya **batas pengisian di firmware** lewat `bfD0`/`bfE0`. Firmware sendiri yang
  menghentikan dan melanjutkan pengisian, jadi kemungkinan besar tetap bekerja saat Mac tidur. Ini membuat
  ChargeCap jauh lebih sederhana: daemon cukup **menulis kedua nilai dan memastikan nilainya tidak berubah**
  (setelah bangun, setelah restart, setiap beberapa menit), bukan memantau persen terus-menerus.
  Contoh batas 80%: `bfD0 = 50000000` (80), `bfE0 = 4b000000` (75).
- Karena itu Fase 0 dipecah: **0a mengamati AlDente** (hanya baca) untuk menemukan tombol yang dipakainya,
  baru **0b menulis** tombol itu sendiri.

## 2c. Temuan 3 Nov 2026: `bfD0`/`bfE0` saja tidak cukup, ada `bfF0` (mode)

- **Fase 0b percobaan 1** (`logs/phase0-write-2026-11-03T10-20-22-main`): menulis `bfD0`/`bfE0` lewat `smc-rw`
  berhasil terbaca balik, dan batas 100% membuat pengisian jalan. Tetapi dengan `bfD0=80% bfE0=75%`
  pengisian **tidak berhenti**; setelah nilai awal (80/79) dipulihkan baterai terus naik ke 83%.
  Jadi dua tombol itu **bukan** saklar sendiri.
- **`bfF0` (ui8) adalah mode/pengaktif.** Tercatat `02` selama AlDente membatasi (di snapshot Fase 0a, mengisi
  maupun berhenti) dan `00` setelah AlDente ditutup. String di biner AlDente menyebut `bfF0` bersama
  `bfD0` dan `bfE0` (urutan `bfF0, bfD0, bfE0`). Hipotesis: `bfF0=02` menyalakan batas firmware.
  `smc-rw` sekarang boleh menulis `bfF0` (1 byte). Percobaan 2 menguji hipotesis ini.
- Catatan: satu tulisan `bfD0=80%` sempat mengembalikan `SMC error 0x89` walau nilainya terbaca berubah;
  penyebab belum diketahui.
- **Percobaan 2** (`logs/phase0-write-2026-11-03T10-28-40-main`): `bfF0=02` ditulis tetapi **kembali ke 00**
  sendiri, dan penulisan `bfD0` dijawab `SMC error 0x89`. Penyebab: firmware menolak konfigurasi dengan
  `bfD0` (berhenti) < `bfE0` (mulai lagi) dan mematikan `bfF0`.
- **Percobaan 3, BERHASIL** (log `phase0-write-2026-11-03T10-36-32-main`): dengan urutan tulis yang benar
  pengisian **berhenti dalam ±50 detik** (92%/87%), bertahan, dan jalan lagi saat batas 100%.
  `NotChargingReason=36028797018963968`, sama seperti saat AlDente menghentikan pengisian.
  **Resep:** menyalakan = tulis `bfE0`, lalu `bfD0`, lalu `bfF0=02` (terakhir). Mematikan = `bfF0=00` dulu,
  lalu `bfD0`, lalu `bfE0`. Invarian: `bfD0 >= bfE0` di setiap saat; saat menurunkan, `bfE0` dulu; saat
  menaikkan, `bfD0` dulu.
- **Belum diuji:** bertahan saat tidur (uji tidur dilewati 3 Nov), bertahan setelah restart
  (`--reboot-test`/`--after-reboot`), dan apa arti `bfI0`.
- Skrip uji diperbaiki: error sintaks bash 3.2 (`case` di dalam `$(...)`), langkah tunggu kini selalu jalan
  (dulu terlewat bila tulisan gagal), menunggu 240 detik untuk berhenti, `bfF0` ikut dicatat dan dipulihkan.

## 3. Yang kita pelajari dari AlDente

AlDente = **aplikasi menu bar** (yang memutuskan) + **helper root** `com.apphousekitchen.aldente-pro.helper`
(yang menulis ke chip SMC lewat IOKit `AppleSMC`). Aplikasi mengirim perintah ke helper lewat XPC;
helper mengecek tanda tangan pengirim dulu.

### Tombol SMC yang terbukti dipakai (dari kode AlDente)

| Tujuan | Mac Apple Silicon (seperti punyamu) | Mac lama / Intel | Bukti |
|---|---|---|---|
| **Boleh mengisi** | `CHTE` (32-bit) = `0x00000000`, `CHIE` (8-bit) = `0x00` | `CH0B`, `CH0I`, `CH0C` = `0x00` | fungsi `sub_100224080` (Hopper) |
| **Berhenti mengisi** | `CHTE` (32-bit) = `0x01000000` | `CH0C` = `0x01` | fungsi `FUN_1002243c4` (Ghidra) |
| **Lepas charger / paksa pakai baterai** (dugaan kuat) | `CHIE` (8-bit) = `0x08` | `CHIE` = `0x01` (?) | fungsi `FUN_1002243c4` (Ghidra) |

Catatan:
- `FUN_1002243c4` menulis `CHTE = 0x01000000` **dan** `CHIE = 0x08` sekaligus, jadi kemungkinan besar itu
  fungsi *discharge* (berhenti mengisi + lepas charger). Untuk sekadar "berhenti di 80%" cukup `CHTE = 0x01000000`.
  **Fase 0 wajib memastikan ini di Mac kamu.**
- Teks `CHTE` tidak tertulis utuh di kode; Swift membuatnya dari `"CHIE" + 0xb0000`.
- AlDente memilih tombol berdasarkan model Mac (`HardwareManager.mbModel`) dan punya beberapa "backend"
  (`TahoeSMCBackend`, `GoldenGateSMCBackend`, `LegacyIntelSMCBackend`). Kita cukup dukung satu Mac: punyamu.

### Dugaan kenapa AlDente tembus ke 100% (belum dibuktikan)

1. **Mac tidur saat dicas.** Kalau batasnya dijaga oleh aplikasi menu bar, aplikasi itu ikut tidur dan
   tidak sempat menulis "berhenti mengisi".
2. **Helper/aplikasi tidak jalan** atau versinya tidak cocok setelah update.
3. **Status SMC di-reset firmware** saat tidur/bangun, lalu tidak ditulis ulang.

Desain ChargeCap di bawah sengaja menutup ketiga celah ini.

## 4. Desain ChargeCap

```
┌────────────────────┐   XPC (Mach service)   ┌──────────────────────────┐
│ chargecap (CLI)        │ ─────────────────────▶ │ chargecapd (LaunchDaemon, │
│ ChargeCap.app (nanti)│ ◀───────────────────── │ root)                    │
└────────────────────┘    status / setelan    │  • baca % baterai        │
                                              │  • putuskan isi / berhenti│
                                              │  • tulis SMC (IOKit)     │
                                              │  • tangani tidur/bangun  │
                                              └──────────────────────────┘
```

Prinsip utama: **daemon root yang memegang keputusan**, bukan aplikasi menu bar. Daemon tetap jalan walau
aplikasi ditutup atau tidak ada yang login.

### Komponen

1. **`SMCKit` (library Swift kecil)**
   - Buka `AppleSMC` dengan `IOServiceGetMatchingService` + `IOServiceOpen`.
   - Baca/tulis tombol lewat `IOConnectCallStructMethod` (struktur `SMCParamStruct`, perintah read-key-info / read / write), sama seperti helper AlDente.
   - Fungsi: `read(key)`, `write(key, bytes)`.

2. **`chargecapd` (daemon)**
   - Dipasang sebagai `/Library/LaunchDaemons/dev.kelvin.chargecap.plist`, jalan sebagai root, `KeepAlive`.
   - Baca baterai lewat `IOPSCopyPowerSourcesInfo` / `AppleSmartBattery` (`CurrentCapacity`, `ExternalConnected`, `IsCharging`).
   - Aturan dengan histeresis (supaya tidak bolak-balik):
     - `% >= batas` → tulis **berhenti mengisi**.
     - `% <= batas - 5` → tulis **boleh mengisi**.
   - Pemicu: notifikasi perubahan baterai (`IOPSNotificationCreateRunLoopSource`) + timer cadangan tiap 60 detik.
   - Tidur/bangun (`IORegisterForSystemPower`):
     - **Sebelum tidur:** kalau `% >= batas - 5`, pastikan status "berhenti mengisi" tertulis.
     - **Setelah bangun:** baca ulang tombol SMC dan tulis ulang kalau berubah.
     - Kalau Fase 0 membuktikan status SMC hilang saat tidur, opsi cadangan: tahan Mac agar tidak tidur
       selama dicas dan `% < batas` (pakai `IOPMAssertionCreateWithName`, seperti AlDente), atau berhenti
       mengisi lebih awal sebelum tidur.
   - Saat daemon berhenti/di-uninstall: tulis **boleh mengisi** (kembalikan normal).
   - Log ke `/var/log/chargecap.log` (atau `os_log`) setiap kali menulis SMC.

3. **`chargecap` (CLI)** — untuk dipakai dan diuji dari Terminal:
   - `chargecap status` → %, mengisi/tidak, nilai `CHTE`/`CHIE` saat ini, batas aktif.
   - `chargecap limit 80` → atur batas.
   - `chargecap reset` → kembalikan semua ke normal (tombol darurat).
   - `chargecap logs`.

4. **`ChargeCap.app` (menu bar, fase akhir)** — SwiftUI `MenuBarExtra`: tampilkan %, slider batas, status.

### Kenapa XPC Mach service

Daemon mendaftarkan Mach service di plist (`MachServices`). CLI/aplikasi terhubung lewat `NSXPCConnection`.
Untuk pemakaian pribadi cukup cek bahwa pengirim adalah user kamu (UID); pengecekan tanda tangan kode
seperti AlDente opsional.

### Penandatanganan

Untuk Mac sendiri: **ad-hoc signing** (`codesign -s -`) sudah cukup. Tidak perlu akun Apple Developer.
Daemon dipasang manual dengan skrip `install.sh` (pakai `sudo`), bukan `SMJobBless`.

## 5. Tahapan kerja

### Fase 0a — Amati AlDente (hanya baca, tanpa sudo) — SIAP DIJALANKAN

Alat: `smc-rw` (`swift build -c release`) dan `scripts/phase0-observe.sh`.
Skrip memotret semua tombol SMC saat AlDente membiarkan mengisi, saat AlDente menghentikan, dan saat mengisi
lagi, lalu menampilkan tombol yang berubah. Hasil otomatis tersimpan di `logs/phase0-observe-<waktu>/`
(`summary.log`, `steps.jsonl`, snapshot `*.txt`, `candidates-3way.txt`).

Syarat: AlDente terbuka, charger terpasang, baterai < 95%.

Kemungkinan hasil:
- Ada tombol yang berubah lalu kembali → itu tombol "berhenti mengisi" untuk Mac ini → lanjut 0b.
- Tidak ada yang berubah → AlDente memakai mekanisme macOS lain (bukan SMC) → kita selidiki dengan REA.

### Fase 0b — Eksperimen tulis (±30–45 menit), WAJIB sebelum menulis daemon

Langkah di bawah ditulis untuk `CHTE`; **untuk Mac ini pakai `bfD0`/`bfE0`** (sudah masuk daftar izin
tulis `smc-rw`). Skenario 0b yang baru, dengan **AlDente ditutup**:
1. Catat `bfD0`/`bfE0` awal.
2. Baterai X% → tulis `bfD0 = X-1`, `bfE0 = X-6` → pengisian harus berhenti.
3. Tulis `bfD0 = 100`, `bfE0 = 99` → pengisian harus jalan lagi.
4. Uji tidur: tulis batas di bawah persen sekarang, tidur 15 menit, cek persen tidak naik dan nilai tetap.
5. Uji restart: setelah reboot, apakah `bfD0`/`bfE0` masih sama atau kembali ke 100/99?
6. Akhiri dengan `bfD0 = 100`, `bfE0 = 99` (normal).

Tujuan: membuktikan tombol SMC di Mac kamu, bukan cuma percaya kode AlDente.

1. **Matikan AlDente dulu** (Quit, dan matikan helper-nya) supaya tidak ada dua program yang menulis SMC.
2. Matikan **Optimized Battery Charging** di System Settings → Battery.
3. Buat alat kecil `smc-rw` (Swift, ~150 baris) untuk baca/tulis satu tombol.
4. Dengan charger terpasang dan baterai di bawah 100%:
   - Baca nilai awal `CHTE`, `CHIE` (catat!).
   - Tulis `CHTE = 0x01000000` → cek `pmset -g batt` (harus "not charging") dan `ChargerInhibitReason` di `ioreg`.
   - Tulis `CHTE = 0x00000000` → cek pengisian jalan lagi.
   - (Opsional) Tulis `CHIE = 0x08` → cek Mac pindah ke baterai walau charger terpasang; lalu kembalikan `CHIE = 0x00`.
5. **Uji tidur:** set `CHTE = 0x01000000`, tutup layar 15 menit, buka lagi, baca `CHTE` dan % baterai.
   Hasil ini menentukan strategi tidur di Fase 1.

Kriteria lulus: kita tahu pasti nilai "berhenti" dan "boleh mengisi", dan tahu apakah status bertahan saat tidur.

#### Log otomatis Fase 0 (tidak perlu mencatat manual)

Semua langkah di atas dijalankan lewat satu skrip `phase0.sh` yang memanggil `smc-rw`. Skrip ini menyimpan
semua hasil sendiri ke folder `chargecap/logs/`:

```
chargecap/logs/
├── phase0-2026-10-24T09-30-00.log     ← ringkasan yang mudah dibaca manusia
└── phase0-2026-10-24T09-30-00.jsonl   ← satu baris JSON per langkah, untuk dibaca ulang/dibandingkan
```

Setiap langkah mencatat:
- **waktu** dan **nama langkah** (misalnya `tulis CHTE=0x01000000`);
- nilai `CHTE` dan `CHIE` **sebelum** dan **sesudah** ditulis (dibaca ulang dari SMC, bukan diasumsikan);
- % baterai, `ExternalConnected`, `IsCharging`, `ChargerInhibitReason`, `NotChargingReason` dari `ioreg`;
- baris status `pmset -g batt`;
- **lulus / gagal** otomatis (misalnya "berhenti mengisi" lulus kalau `IsCharging = No` setelah ±30 detik).

Untuk uji tidur, skrip mencatat status sebelum tidur, menunggu kamu menutup dan membuka layar, lalu mencatat
lagi setelah bangun. Kejadian tidur/bangun dari `pmset -g log` juga ikut disalin ke log.

Di akhir, skrip **selalu** mengembalikan `CHTE = 0` dan `CHIE = 0` (juga kalau dihentikan dengan Ctrl+C),
lalu menulis ringkasan jawaban untuk "Pertanyaan terbuka" di bagian 7. Fase 1 nanti memakai log yang sama
(`/var/log/chargecap.log`) dengan format serupa, jadi hasilnya bisa dibandingkan.

### Fase 1 — Daemon + CLI — SELESAI dan teruji di perangkat keras, 3 Nov 2026 (19 tes lulus)

Disederhanakan berkat temuan Fase 0: **firmware yang menghentikan dan melanjutkan pengisian**, jadi daemon
**tidak memantau persen baterai**. Tugasnya hanya memastikan tiga kunci (`bfF0`, `bfD0`, `bfE0`) berisi yang
diminta `config.json`: saat start, setelah bangun, saat sumber daya berubah, dan tiap 60 detik.

- `ChargeCapCore` (murni, ada tesnya): `Config` (nonaktif secara bawaan, batas 20–100, jarak 1–15),
  `WritePlanner` (urutan tulis; `bfD0 >= bfE0` di setiap saat), `Engine` (baca, bandingkan, tulis selisihnya,
  verifikasi). Tes memakai SMC palsu yang meniru firmware: menolak `bfD0 < bfE0` dengan 0x89 dan mematikan
  `bfF0`; semua perpindahan antar batas diuji dan tidak ada yang memicu penolakan.
- `ChargeCapKit`: `SMCClient` (hanya bisa menulis tiga kunci itu, `bfF0` ∈ {0, 2}, persen 1–100),
  `Battery`, `PowerWatcher` (bangun, ganti sumber daya), `FileLog` (`/var/log/chargecap.log`, ±1 MB).
- `chargecapd`: daemon root. Tidak mengubah kunci saat dihentikan (SIGTERM); mematikan batas hanya lewat
  `chargecap off`/uninstall.
- `chargecap` (CLI): `status` (tanpa root), `sudo limit N`, `sudo off`, `sudo apply`, `logs`. `limit` dan `off`
  langsung diterapkan, jadi bisa dicoba **tanpa memasang daemon**.
- Mematikan batas hanya menulis `bfF0=00`; firmware mengabaikan `bfD0`/`bfE0` saat mode 00.
- **Uji di Mac (3 Nov):** `sudo chargecap limit 90` menulis `bfD0=90, bfE0=85, bfF0=2` tanpa 0x89 dan pengisian
  berhenti di 97%. `scripts/phase1-daemon-test.sh`: `bfF0` dimatikan paksa, daemon mengembalikannya
  `02` dalam ±58 detik (peristiwa power/timer), lalu `chargecap off` mengembalikan pengisian normal.
- Tanpa XPC di Fase 1: CLI menulis `config.json` (root) dan menerapkannya sendiri; daemon membaca ulang
  file itu tiap menit. XPC baru dibutuhkan kalau aplikasi menu bar (Fase 4) harus berjalan tanpa root.

### Fase 2 — Pasang & copot — TERPASANG di Mac Kelvin 3 Nov 2026 (restart belum diuji)
- `scripts/install.sh` (`--dry-run` mengubah tidak ada apa pun): membangun release sebagai user biasa bila perlu,
  menolak jalan kalau AlDente aktif, memasang semuanya milik `root:wheel` (`/usr/local/libexec/chargecap/chargecapd`,
  `/usr/local/bin/chargecap`, `/Library/LaunchDaemons/dev.kelvin.chargecap.plist`, config di
  `/Library/Application Support/ChargeCap/`), `launchctl bootstrap`, lalu memeriksa daemon berjalan. Config baru
  dibuat **mati**; config yang sudah ada tidak diubah.
- `scripts/uninstall.sh` (`--dry-run`, `--purge`): mematikan batas **lebih dulu**, baru menghentikan daemon dan
  menghapus file; config dan log dibiarkan kecuali `--purge`.
- **3 Nov 2026:** `sudo scripts/install.sh` berhasil; daemon jalan (pid dari launchd), mematikan sisa batas AlDente,
  lalu `sudo chargecap limit 80` dengan baterai 93%: pengisian berhenti dalam ±20 detik dan `status` sesuai.
- Uji yang tersisa: **restart** (daemon harus jalan sendiri dan batas tetap ada) dan uji tidur.

### Fase 3 — Uji ketahanan (beberapa hari)
- Alat: `chargecap report` (3 Nov 2026, dites) membandingkan `DailyMaxSoc` dari gauge baterai dengan batas
  (toleransi +1) dan merangkum log daemon 24 jam: start, bangun, tulis ulang, gagal.
- Uji semalam dengan layar tertutup + dicas. Pagi harinya jalankan `chargecap report` (target: tertinggi ≤ batas + 1).
- Uji restart, logout, update macOS minor.

### Fase 4 — Aplikasi menu bar (±1 hari)
- `MenuBarExtra` SwiftUI, dibangun dengan SwiftPM lalu dibungkus jadi `.app` dengan skrip (tanpa Xcode).

### Fase 5 — Opsional
- *Sailing* (biarkan turun ke batas-x% sebelum isi lagi) — sebenarnya sudah tercakup histeresis.
- *Heat protection*: berhenti mengisi kalau suhu baterai tinggi (baca suhu dari `AppleSmartBattery`/SMC).
- *Discharge* manual (`CHIE = 0x08`).
- *Top up* sekali ke 100% sebelum bepergian.

## 6. Keamanan

- Yang kita tulis hanya tombol pengisian yang juga dipakai AlDente; risikonya rendah. Tetap:
  - Selalu catat nilai awal sebelum menulis.
  - `chargecap reset` dan `uninstall.sh` selalu mengembalikan `CHTE = 0`, `CHIE = 0`.
  - Jangan pernah menulis tombol selain daftar di atas.
- Kalau ada yang aneh: `sudo chargecap reset`, atau cabut daemon. Reset SMC Apple Silicon = matikan Mac, tunggu 30 detik, nyalakan.
- **AlDente harus dicopot/dimatikan** sebelum ChargeCap dipakai, supaya tidak saling menimpa.

## 7. Pertanyaan terbuka (dijawab di Fase 0)

1. Apakah `CHTE = 0x01000000` saja cukup untuk berhenti mengisi di M1 Pro + macOS 15.8.1?
2. Apakah nilai `CHTE` bertahan saat Mac tidur/bangun?
3. Apakah firmware mengembalikan `CHTE` sendiri setelah restart (kemungkinan iya → daemon menulis ulang saat start)?
4. Apa arti `CHIE = 0x01` di cabang Mac lama? (Tidak penting untuk Mac kamu.)

## 8. Bahan rujukan di folder ini

- `aldente/extracted/AlDente.app` — aplikasi AlDente 1.39.4 hasil ekstrak (tidak diinstal).
- Fungsi AlDente yang relevan (alamat arm64):
  - `0x100224080` — tulis "boleh mengisi" (`CHIE`, `CHTE`, `CH0B`, `CH0I`, `CH0C` = 0).
  - `0x1002243c4` — tulis `CHTE = 0x01000000`, `CHIE = 0x08` / `CH0C = 1`, `CHIE = 1`.
- REA sekarang memakai **Ghidra 12.1.4** (`~/Applications/ghidra_12.1.4_PUBLIC`). Analisis aplikasi besar butuh
  `REA_GHIDRA_STARTUP_TIMEOUT_MS=1800000` dan ±7 menit per perintah.
