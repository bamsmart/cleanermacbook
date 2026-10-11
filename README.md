# 🧹 CleanerMac — Cache, Storage & Performance Booster untuk macOS

Script satu file (Python 3, tanpa dependency) untuk **membersihkan cache & storage yang tidak perlu** serta **mengecek faktor yang bikin Mac lambat**: memory pressure, swap, thermal, proses boros, dan agent startup.

Dibuat dengan prinsip **aman dulu**: ada preview (dry-run), konfirmasi untuk item berisiko, laporan ruang yang dibebaskan, dan log setiap kali dijalankan.

---

## 🚀 Cara Menjalankan

### 1. Double-click (paling mudah)
Double-click **`Bersihkan_Mac.command`** di Finder. Terminal terbuka dan muncul menu:

```
1) Health check & audit startup  (tidak menghapus apa pun)
2) Preview pembersihan           (dry-run)
3) Pembersihan aman              (direkomendasikan)
4) Pembersihan agresif           (Gradle, Maven, Go mod, settings IDE lama, dll)
5) Optimasi tampilan             (Reduce Transparency & Motion)
0) Keluar
```

> Jika muncul peringatan *"cannot be opened because it is from an unidentified developer"*: klik kanan file → **Open** → **Open**.

### 2. Lewat terminal (Terminal.app / terminal Antigravity / IDE)
```bash
cd ~/PycharmProjects/CleanerMacBook
chmod +x Bersihkan_Mac.command      # cukup sekali
./Bersihkan_Mac.command             # menu interaktif
```

---

## ⚙️ Opsi Command Line

| Flag | Fungsi |
|------|--------|
| `--dry-run` | Preview saja: tampilkan apa yang akan dihapus beserta ukurannya, **tanpa menghapus** |
| `-y`, `--yes` | Setujui semua konfirmasi otomatis (untuk otomasi / cron) |
| `--aggressive` | Pembersihan lebih dalam (lihat tabel di bawah) |
| `--only <kategori>` | Jalankan kategori tertentu saja, dipisah koma |
| `--health` | Health check + audit startup + laporan storage saja |
| `--flush-dns` | Flush DNS cache *(butuh password admin)* |
| `--purge` | Lepaskan RAM file cache *(butuh admin, biasanya tidak perlu)* |
| `--reindex-spotlight` | Bangun ulang index Spotlight *(butuh admin)* |
| `--docker-volumes` | Ikut hapus volume Docker tak terpakai ⚠️ **data DB lokal bisa hilang** |
| `--ui-light` | Aktifkan Reduce Transparency & Reduce Motion |
| `--init-config` | Buat file config `~/.config/cleanermac.json` |

**Kategori untuk `--only`:** `startup`, `dev`, `projects`, `browser`, `system`, `reports`

### Contoh
```bash
./Bersihkan_Mac.command --dry-run                 # lihat dulu apa yang akan dihapus
./Bersihkan_Mac.command --yes                     # pembersihan aman tanpa tanya
./Bersihkan_Mac.command --aggressive              # pembersihan dalam (tetap ada konfirmasi)
./Bersihkan_Mac.command --only dev,browser        # hanya cache developer & browser
./Bersihkan_Mac.command --health                  # cek kondisi Mac saja
./Bersihkan_Mac.command --yes --flush-dns         # bersihkan + flush DNS
```

---

## 🧽 Apa Saja yang Dibersihkan

| Kategori | Mode Aman | Tambahan di Mode Agresif |
|----------|-----------|--------------------------|
| **Developer** | Xcode DerivedData, CoreSimulator Caches, simulator *unavailable*, DeviceSupport lama (simpan versi terbaru), Gradle daemon logs, Android cache, cache/log JetBrains versi lama, cache pip / uv / conda / npm / yarn / pnpm / bun / CocoaPods / Go build / Cargo, `brew cleanup`, `docker system prune` (tanpa volume) | Xcode Archives > 180 hari, Gradle caches, Go module cache, Flutter pub cache, Maven `~/.m2`, settings/plugin JetBrains versi lama, `brew autoremove`, `docker prune -a` |
| **Project** | `node_modules` di project yang tidak disentuh > **30 hari**, folder `__pycache__` | `node_modules` tidak aktif > **7 hari**, virtualenv (`venv`/`.venv`) tidak aktif > 90 hari |
| **Browser** | Chrome, Edge, Brave, Arc, Vivaldi, Chromium, Opera: Service Worker CacheStorage, Code Cache, GPU/Shader cache *(dilewati jika browser sedang berjalan)* | — |
| **Sistem** | `~/Library/Caches` (dengan exclude list & skip app yang sedang berjalan), `~/Library/Logs`, Mail Downloads, cache QuickLook, Trash, snapshot lokal Time Machine | Cache JetBrains di `~/Library/Caches`, reset cache font, rebuild LaunchServices |

## 🩺 Health Check & Laporan (tidak menghapus apa pun)

- **Disk:** ruang kosong, peringatan jika < 15%
- **Memori:** RAM bebas (memory pressure) & swap terpakai
- **Uptime:** saran restart jika > 7 hari
- **Thermal:** deteksi CPU throttling
- **Top 5 proses** paling boros CPU & memori (deteksi Spotlight indexing / `kernel_task` panas)
- **Audit startup:** LaunchAgents & LaunchDaemons pihak ketiga. User Agent bisa dinonaktifkan langsung dari menu; file dipindah ke `~/Library/LaunchAgents.disabled/` dan bisa dikembalikan
- **Laporan storage:** backup iPhone, lampiran iMessage, Xcode Archives, data Simulator, file lama di Downloads, file > 1 GB di home

---

## 🛡️ Keamanan

Yang **tidak** akan dihapus tanpa izin eksplisit:

- ❌ **Volume Docker**, hanya dengan flag `--docker-volumes` + konfirmasi
- ❌ **Xcode Archives** (berisi dSYM untuk symbolicate crash), hanya yang > 180 hari di mode agresif
- ❌ **Data simulator iOS**, yang dihapus hanya simulator *unavailable*
- ❌ **`node_modules` project aktif**, hanya project tidak aktif > 30 hari
- ❌ **Cache aplikasi yang sedang berjalan**
- ❌ Cache penting: iCloud (`com.apple.bird`), CloudKit, HomeKit, download yang tertunda, Spotify offline

Fitur pengaman lainnya:

- ✅ Konfirmasi untuk Trash, node_modules, DeviceSupport, dan semua item agresif
- ✅ Menolak berjalan dengan `sudo`; izin admin diminta lewat dialog macOS (Touch ID / password) hanya untuk DNS, purge, Time Machine, dan Spotlight
- ✅ Log lengkap di `~/Library/Logs/CleanerMac/clean-YYYYMMDD-HHMMSS.log`

> [!TIP]
> Selalu jalankan `--dry-run` dulu bila ragu.

---

## 🔐 Full Disk Access (disarankan)

Tanpa izin ini, **Trash**, **Mail Downloads**, dan beberapa folder lain dilewati.

1. **System Settings › Privacy & Security › Full Disk Access**
2. Aktifkan aplikasi yang menjalankan script:
   - **Terminal**, untuk double-click
   - **Antigravity IDE** / PyCharm / iTerm, jika dijalankan dari terminal aplikasi tersebut
3. **Tutup aplikasi tersebut (⌘Q) lalu buka lagi** agar izin aktif

---

## 🛠️ Konfigurasi

Buat file config:
```bash
./Bersihkan_Mac.command --init-config
```

Lalu edit `~/.config/cleanermac.json`:

| Key | Default | Keterangan |
|-----|---------|------------|
| `project_dirs` | `~/Projects`, `~/Documents`, `~/PycharmProjects`, dll | Folder yang dipindai untuk `node_modules` / venv |
| `node_modules_stale_days` | `30` | Hari tidak aktif sebelum `node_modules` dihapus (mode aman) |
| `node_modules_stale_days_aggressive` | `7` | Sama, untuk mode agresif |
| `venv_stale_days` | `90` | Hari tidak aktif untuk virtualenv |
| `trash_min_age_days` | `0` | Hanya hapus item Trash yang lebih tua dari N hari |
| `downloads_old_days` | `90` | Ambang "file lama" di laporan Downloads |
| `archives_old_days` | `180` | Ambang Xcode Archives lama |
| `large_file_gb` | `1` | Ambang file besar di laporan |
| `cache_excludes` | iCloud, CloudKit, HomeKit, Spotify, dll | Folder di `~/Library/Caches` yang tidak boleh dihapus |
| `cache_excludes_safe_mode` | `JetBrains` | Exclude tambahan khusus mode aman |

---

## 💡 Tips Agar Mac Tetap Cepat

- **Sisakan minimal 15–20% disk kosong.** macOS butuh ruang untuk swap & update.
- **Restart seminggu sekali** untuk mengosongkan swap & proses yang bocor memori.
- **Kurangi agent startup** di *System Settings › General › Login Items & Extensions*.
- **Exclude folder dev dari Spotlight** (`node_modules`, `DerivedData`) di *Siri & Spotlight › Spotlight Privacy*.
- **Tutup tab browser yang berat.** Chrome renderer sering memakan lebih dari 1 GB RAM.
- **`purge` RAM biasanya tidak perlu.** macOS mengelola memori sendiri, dan aplikasi justru lebih lambat sesaat setelah purge.
- **Cache akan terbentuk lagi** saat aplikasi dipakai, dan ini normal. Jalankan script ini sebulan sekali saja.

---

## 📋 Kebutuhan

- macOS (diuji di macOS 26)
- Python 3 (`/usr/bin/python3` bawaan Xcode Command Line Tools, atau Homebrew)
- Tanpa library tambahan
