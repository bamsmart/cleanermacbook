#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CleanerMac — Pembersih cache/storage & booster performa macOS.

Cara pakai:
  Double-click file ini              → menu interaktif
  ./Bersihkan_Mac.command --help     → lihat semua opsi

Contoh:
  ./Bersihkan_Mac.command --dry-run            # preview, tidak menghapus apa pun
  ./Bersihkan_Mac.command --yes                # pembersihan aman tanpa bertanya
  ./Bersihkan_Mac.command --aggressive         # pembersihan lebih dalam (tetap minta konfirmasi)
  ./Bersihkan_Mac.command --only dev,projects  # hanya kategori tertentu
  ./Bersihkan_Mac.command --health             # health check saja
  ./Bersihkan_Mac.command --init-config        # buat file config ~/.config/cleanermac.json
"""
import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HOME = Path.home()
CONFIG_PATH = HOME / ".config" / "cleanermac.json"
LOG_DIR = HOME / "Library" / "Logs" / "CleanerMac"
DAY = 86400
GB = 1024 ** 3

DEFAULT_CONFIG = {
    "project_dirs": [
        "~/Projects", "~/Documents", "~/Developer", "~/Sites", "~/Code",
        "~/PycharmProjects", "~/StudioProjects", "~/IdeaProjects", "~/WebstormProjects",
    ],
    # node_modules hanya dihapus bila project tidak disentuh selama N hari
    "node_modules_stale_days": 30,
    "node_modules_stale_days_aggressive": 7,
    # .venv yang tidak disentuh selama N hari dilaporkan (dihapus hanya di mode agresif)
    "venv_stale_days": 90,
    # Item di Trash yang lebih muda dari N hari tidak dihapus (0 = semua)
    "trash_min_age_days": 0,
    "downloads_old_days": 90,
    "archives_old_days": 180,
    "large_file_gb": 1,
    # Folder top-level di ~/Library/Caches yang TIDAK boleh dihapus
    "cache_excludes": [
        "CloudKit", "com.apple.bird", "com.apple.nsurlsessiond", "com.apple.HomeKit",
        "FamilyCircle", "com.apple.containermanagerd", "com.apple.ap.adprivacyd",
        "com.spotify.client", "CleanerMac",
    ],
    # Tambahan exclude di mode aman (dihapus hanya di mode agresif)
    "cache_excludes_safe_mode": ["JetBrains"],
}

CATEGORIES = {
    "startup": "Startup & Login Items",
    "dev": "Developer",
    "projects": "Project (node_modules, venv)",
    "browser": "Browser",
    "system": "Sistem & Cache",
    "reports": "Laporan Storage",
}
PROJECT_WALK_SKIP = {
    ".git", ".hg", ".svn", ".idea", ".vscode", "__pycache__", "Pods", "DerivedData",
    ".gradle", "build", "dist", ".next", ".cache", "Library", "Mobile Documents",
}

_TTY = sys.stdout.isatty()


def _c(code):
    return code if _TTY else ""


BLUE, GREEN, YELLOW, RED, CYAN, DIM, BOLD, RESET = (
    _c("\033[1;34m"), _c("\033[32m"), _c("\033[33m"), _c("\033[31m"),
    _c("\033[1;36m"), _c("\033[2m"), _c("\033[1m"), _c("\033[0m"),
)
ANSI_RE = re.compile(r"\033\[[0-9;]*m")


# ─────────────────────────────── Utilitas ────────────────────────────────

def fmt(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{int(n)} B" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def path_size(p):
    """Ukuran nyata di disk (st_blocks) — tidak mengikuti symlink, aman dari error izin."""
    p = str(p)
    try:
        st = os.lstat(p)
    except OSError:
        return 0
    if not stat.S_ISDIR(st.st_mode):
        return st.st_blocks * 512
    total, stack = 0, [p]
    while stack:
        d = stack.pop()
        try:
            with os.scandir(d) as it:
                for e in it:
                    try:
                        if e.is_dir(follow_symlinks=False):
                            stack.append(e.path)
                        else:
                            total += e.stat(follow_symlinks=False).st_blocks * 512
                    except OSError:
                        pass
        except OSError:
            pass
    return total


def last_activity(st):
    return max(st.st_mtime, getattr(st, "st_birthtime", 0))


def run(cmd, timeout=300):
    """Jalankan perintah (list, tanpa shell). Return (returncode, output)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except FileNotFoundError:
        return 127, ""
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except OSError as e:
        return 1, str(e)


def is_process_running(name):
    rc, _ = run(["pgrep", "-x", name], timeout=10)
    return rc == 0


def running_bundle_ids():
    _, out = run(["lsappinfo", "list"], timeout=15)
    return {m.lower() for m in re.findall(r'bundleID="([^"]+)"', out)}


def disk_stats():
    root = "/System/Volumes/Data" if os.path.isdir("/System/Volumes/Data") else "/"
    return shutil.disk_usage(root)


def load_config():
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    if CONFIG_PATH.exists():
        try:
            cfg.update(json.loads(CONFIG_PATH.read_text(encoding="utf-8")))
        except (OSError, ValueError) as e:
            print(f"{YELLOW}! Config {CONFIG_PATH} tidak valid ({e}), memakai default.{RESET}")
    cfg["project_dirs"] = [Path(p).expanduser() for p in cfg["project_dirs"]]
    return cfg


# ─────────────────────────────── Context ────────────────────────────────

class Ctx:
    def __init__(self, args, cfg):
        self.args = args
        self.cfg = cfg
        self.dry_run = args.dry_run
        self.yes = args.yes
        self.aggressive = args.aggressive
        self.interactive = sys.stdin.isatty()
        self.category = "Lainnya"
        self.freed = {}
        self.recs = []
        self.admin_cmds = []  # (deskripsi, perintah shell) — dijalankan sekali dengan 1 prompt password
        self.need_fda = False
        self.running_ids = running_bundle_ids()
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        self.log_path = LOG_DIR / f"clean-{datetime.now():%Y%m%d-%H%M%S}.log"
        self._log = open(self.log_path, "a", encoding="utf-8")

    # ── output ──
    def log(self, msg):
        self._log.write(f"[{datetime.now():%H:%M:%S}] {ANSI_RE.sub('', msg)}\n")
        self._log.flush()

    def _out(self, msg):
        print(msg)
        self.log(msg)

    def step(self, title):
        self._out(f"\n{BLUE}==> {title}{RESET}")

    def ok(self, msg):
        self._out(f"  {GREEN}✔{RESET} {msg}")

    def warn(self, msg):
        self._out(f"  {YELLOW}!{RESET} {msg}")

    def info(self, msg):
        self._out(f"  {DIM}•{RESET} {msg}")

    def rec(self, msg):
        if msg not in self.recs:
            self.recs.append(msg)

    def add_freed(self, n):
        self.freed[self.category] = self.freed.get(self.category, 0) + n

    def confirm(self, question, default=False):
        if self.dry_run or self.yes:
            return True
        if not self.interactive:
            return default
        hint = "Y/n" if default else "y/N"
        try:
            ans = input(f"  {CYAN}?{RESET} {question} [{hint}] ").strip().lower()
        except EOFError:
            return default
        self.log(f"? {question} -> {ans or 'default'}")
        return default if not ans else ans in ("y", "ya", "yes")

    def size_tag(self, n):
        return f"{fmt(n)}{' (estimasi)' if self.dry_run else ''}"

    # ── operasi file ──
    def remove_path(self, p, label=None, quiet=False):
        p = Path(p).expanduser()
        if not p.exists() and not p.is_symlink():
            return 0
        before = path_size(p)
        if self.dry_run:
            self.add_freed(before)
            if not quiet:
                self.info(f"[dry-run] akan dihapus: {label or p} ({fmt(before)})")
            return before
        try:
            if p.is_dir() and not p.is_symlink():
                shutil.rmtree(p, ignore_errors=True)
            else:
                p.unlink(missing_ok=True)
        except PermissionError:
            self.need_fda = True
            self.warn(f"Tidak ada izin menghapus: {p}")
            return 0
        except OSError as e:
            self.warn(f"Gagal menghapus {p}: {e}")
            return 0
        after = path_size(p) if p.exists() else 0
        freed = max(before - after, 0)
        self.add_freed(freed)
        if not quiet:
            if after:
                self.warn(f"Sebagian terhapus: {label or p} ({fmt(freed)} dibebaskan, {fmt(after)} tersisa)")
            else:
                self.ok(f"Dihapus: {label or p} ({fmt(freed)})")
        return freed

    def clear_dir_contents(self, d, label=None, excludes=(), min_age_days=0, use_ctime=False):
        d = Path(d).expanduser()
        if not d.is_dir():
            return 0
        try:
            entries = list(d.iterdir())
        except PermissionError:
            self.need_fda = True
            self.warn(f"Tidak ada izin akses {d} (beri Full Disk Access ke Terminal)")
            return 0
        except OSError:
            return 0
        excl = {e.lower() for e in excludes}
        cutoff = time.time() - min_age_days * DAY
        total = skipped = 0
        for e in entries:
            if e.name.lower() in excl:
                skipped += 1
                continue
            if min_age_days:
                try:
                    st = e.lstat()
                    ref = st.st_ctime if use_ctime else last_activity(st)
                except OSError:
                    continue
                if ref > cutoff:
                    skipped += 1
                    continue
            total += self.remove_path(e, quiet=True)
        name = label or str(d)
        extra = f", {skipped} item dilewati" if skipped else ""
        if total:
            (self.info if self.dry_run else self.ok)(
                f"{'[dry-run] ' if self.dry_run else ''}{name}: {self.size_tag(total)}{extra}")
        else:
            self.info(f"{name}: sudah bersih{extra}")
        return total

    def run_tool(self, cmd, desc, measure=(), timeout=600):
        """Jalankan tool pembersih bawaan (npm, brew, dll) dan ukur ruang yang dibebaskan."""
        if not shutil.which(cmd[0]):
            return
        paths = [Path(p).expanduser() for p in measure]
        before = sum(path_size(p) for p in paths)
        if self.dry_run:
            self.add_freed(before)
            size = f" (~{fmt(before)})" if paths else ""
            self.info(f"[dry-run] {desc}: `{' '.join(cmd)}`{size}")
            return
        rc, out = run(cmd, timeout)
        after = sum(path_size(p) for p in paths)
        freed = max(before - after, 0)
        self.add_freed(freed)
        if rc == 0:
            self.ok(f"{desc}" + (f" ({fmt(freed)})" if paths else ""))
        else:
            self.warn(f"{desc} gagal (kode {rc})")
            self.log(out[-800:])


# ─────────────────────────── Health check (P3) ───────────────────────────

def top_processes(sort_flag, n=5):
    _, out = run(["ps", "-Aceo", "pid,pcpu,pmem,rss,comm", sort_flag], timeout=10)
    rows = []
    for line in out.strip().splitlines()[1:n + 1]:
        parts = line.split(None, 4)
        if len(parts) == 5:
            rows.append(parts)
    return rows


def health_check(ctx):
    ctx.step("Health Check")

    du = disk_stats()
    free_pct = du.free / du.total * 100
    ctx.info(f"Disk: {fmt(du.free)} kosong dari {fmt(du.total)} ({free_pct:.0f}% kosong)")
    if free_pct < 10:
        ctx.warn("Disk hampir penuh! macOS butuh ruang kosong untuk swap & update.")
        ctx.rec("Disk < 10% kosong — prioritaskan hapus file besar (lihat Laporan Storage).")
    elif free_pct < 15:
        ctx.rec("Disk < 15% kosong — usahakan sisakan minimal 15-20% agar Mac tetap responsif.")

    _, memsize = run(["sysctl", "-n", "hw.memsize"], timeout=5)
    _, mp = run(["memory_pressure"], timeout=15)
    m = re.search(r"free percentage:\s*(\d+)%", mp)
    ram = f"{fmt(int(memsize.strip()))} RAM" if memsize.strip().isdigit() else "RAM"
    if m:
        free_mem = int(m.group(1))
        ctx.info(f"Memori: {ram}, {free_mem}% bebas (system-wide)")
        if free_mem < 20:
            ctx.rec("Memory pressure tinggi — tutup aplikasi/tab berat (lihat Top Proses di atas).")

    _, sw = run(["sysctl", "-n", "vm.swapusage"], timeout=5)
    m = re.search(r"used = ([\d.]+)([MG])", sw)
    if m:
        used_gb = float(m.group(1)) / (1024 if m.group(2) == "M" else 1)
        ctx.info(f"Swap terpakai: {used_gb:.2f} GB")
        if used_gb > 4:
            ctx.rec(f"Swap {used_gb:.1f} GB — restart Mac untuk mengosongkan swap.")

    _, bt = run(["sysctl", "-n", "kern.boottime"], timeout=5)
    m = re.search(r"sec = (\d+)", bt)
    if m:
        days = (time.time() - int(m.group(1))) / DAY
        ctx.info(f"Uptime: {days:.1f} hari")
        if days > 7:
            ctx.rec(f"Mac belum restart {days:.0f} hari — restart membersihkan swap & proses yang bocor memori.")

    _, th = run(["pmset", "-g", "therm"], timeout=10)
    m = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", th)
    if m and int(m.group(1)) < 100:
        ctx.warn(f"CPU di-throttle karena panas ({m.group(1)}% kecepatan)")
        ctx.rec("CPU throttling — pastikan ventilasi baik, hindari memakai di kasur/sofa.")
    else:
        ctx.info("Thermal: normal")

    print(f"\n  {BOLD}Top proses (CPU){RESET}")
    for pid, cpu, mem, rss, comm in top_processes("-r"):
        ctx._out(f"    {cpu:>5}% CPU  {fmt(int(rss) * 1024):>9}  {comm} {DIM}(pid {pid}){RESET}")
        if comm in ("mds_stores", "mds", "mdworker", "mdworker_shared") and float(cpu) > 20:
            ctx.rec("Spotlight sedang indexing berat — tambahkan folder dev (node_modules, DerivedData) "
                    "ke System Settings › Siri & Spotlight › Spotlight Privacy, atau jalankan --reindex-spotlight.")
        if comm == "kernel_task" and float(cpu) > 50:
            ctx.rec("kernel_task tinggi biasanya tanda Mac kepanasan — dinginkan atau cabut charger sebentar.")
    print(f"  {BOLD}Top proses (Memori){RESET}")
    for pid, cpu, mem, rss, comm in top_processes("-m"):
        ctx._out(f"    {mem:>5}% MEM  {fmt(int(rss) * 1024):>9}  {comm} {DIM}(pid {pid}){RESET}")

    # Cek Full Disk Access
    for probe in (HOME / "Library" / "Mail", HOME / "Library" / "Safari", HOME / ".Trash"):
        if probe.exists():
            try:
                os.listdir(probe)
            except PermissionError:
                ctx.need_fda = True
            break


def audit_startup(ctx):
    ctx.category = CATEGORIES["startup"]
    ctx.step("Audit Startup: LaunchAgents & LaunchDaemons")
    user_dir = HOME / "Library" / "LaunchAgents"
    sources = [
        (user_dir, "User Agent"),
        (Path("/Library/LaunchAgents"), "Global Agent"),
        (Path("/Library/LaunchDaemons"), "Daemon (root)"),
    ]
    user_items, found = [], False
    for d, kind in sources:
        try:
            plists = sorted(p for p in d.glob("*.plist") if not p.name.startswith("com.apple."))
        except OSError:
            continue
        for p in plists:
            found = True
            idx = ""
            if d == user_dir:
                user_items.append(p)
                idx = f"[{len(user_items)}] "
            ctx.info(f"{idx}{kind:<14} {p.stem}")
    if not found:
        ctx.ok("Tidak ada agent pihak ketiga.")
    ctx.info("Login Items aplikasi: System Settings › General › Login Items & Extensions")
    if len(user_items) + (1 if found else 0) > 8:
        ctx.rec("Banyak agent startup — nonaktifkan yang tidak dipakai agar booting & RAM lebih ringan.")

    if not user_items or ctx.dry_run or ctx.yes or not ctx.interactive:
        return
    try:
        ans = input(f"  {CYAN}?{RESET} Nomor User Agent yang ingin dinonaktifkan "
                    f"(pisah koma, kosong = lewati): ").strip()
    except EOFError:
        return
    if not ans:
        return
    disabled_dir = HOME / "Library" / "LaunchAgents.disabled"
    disabled_dir.mkdir(exist_ok=True)
    uid = os.getuid()
    for tok in ans.split(","):
        tok = tok.strip()
        if not tok.isdigit() or not 1 <= int(tok) <= len(user_items):
            continue
        p = user_items[int(tok) - 1]
        run(["launchctl", "bootout", f"gui/{uid}", str(p)], timeout=20)
        try:
            shutil.move(str(p), str(disabled_dir / p.name))
            ctx.ok(f"Dinonaktifkan: {p.stem} (dipindah ke {disabled_dir}, bisa dikembalikan)")
        except OSError as e:
            ctx.warn(f"Gagal menonaktifkan {p.stem}: {e}")


# ─────────────────────────── Cleaner: Developer ──────────────────────────

JB_RE = re.compile(r"^([A-Za-z]+?)(\d{4})\.(\d+)$")


def jetbrains_old_versions(base):
    groups = {}
    try:
        entries = list(base.iterdir())
    except OSError:
        return []
    for e in entries:
        m = JB_RE.match(e.name)
        if m and e.is_dir():
            groups.setdefault(m.group(1), []).append(((int(m.group(2)), int(m.group(3))), e))
    old = []
    for items in groups.values():
        items.sort()
        old += [p for _, p in items[:-1]]
    return old


def clean_dev(ctx):
    ctx.category = CATEGORIES["dev"]
    ctx.step("Membersihkan Cache Developer & Build Tools")
    xc = HOME / "Library" / "Developer"

    # ── Xcode ──
    ctx.clear_dir_contents(xc / "Xcode" / "DerivedData", "Xcode DerivedData")
    ctx.clear_dir_contents(xc / "CoreSimulator" / "Caches", "CoreSimulator Caches")
    _, xpath = run(["xcode-select", "-p"], timeout=10)
    if "Xcode" in xpath and ".app" in xpath:
        ctx.run_tool(["xcrun", "simctl", "delete", "unavailable"], "Simulator yang tidak tersedia dihapus")

    # DeviceSupport: simpan versi terbaru per platform
    for plat in ("iOS", "watchOS", "tvOS", "visionOS"):
        ds = xc / "Xcode" / f"{plat} DeviceSupport"
        if not ds.is_dir():
            continue
        try:
            vers = sorted(ds.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)
        except OSError:
            continue
        old = vers[1:]
        if not old:
            continue
        size = sum(path_size(p) for p in old)
        if size and ctx.confirm(f"Hapus {len(old)} {plat} DeviceSupport lama ({fmt(size)})? "
                                f"Akan dibuat ulang otomatis saat device terhubung.", True):
            for p in old:
                ctx.remove_path(p, f"{plat} DeviceSupport/{p.name}")

    # Archives: JANGAN dihapus default (berisi dSYM untuk symbolicate crash)
    arch = xc / "Xcode" / "Archives"
    if arch.is_dir():
        cutoff = time.time() - ctx.cfg["archives_old_days"] * DAY
        try:
            old = [p for p in arch.iterdir() if p.is_dir() and p.stat().st_mtime < cutoff]
        except OSError:
            old = []
        size = sum(path_size(p) for p in old)
        if old and ctx.aggressive:
            if ctx.confirm(f"Hapus {len(old)} folder Xcode Archives > {ctx.cfg['archives_old_days']} hari "
                           f"({fmt(size)})? dSYM build lama ikut hilang."):
                for p in old:
                    ctx.remove_path(p, f"Archives/{p.name}")
        elif size:
            ctx.info(f"Xcode Archives lama: {fmt(size)} (dihapus hanya di mode --aggressive)")

    # ── Gradle / Android ──
    ctx.remove_path(HOME / ".gradle" / "daemon", "Gradle daemon logs")
    gcache = HOME / ".gradle" / "caches"
    if gcache.exists():
        if ctx.aggressive:
            if ctx.confirm(f"Hapus Gradle caches ({fmt(path_size(gcache))})? Build berikutnya akan download ulang."):
                ctx.remove_path(gcache, "Gradle caches")
        else:
            ctx.info(f"Gradle caches: {fmt(path_size(gcache))} (dihapus hanya di mode --aggressive)")
    ctx.clear_dir_contents(HOME / ".android" / "cache", "Android cache")
    avd = HOME / ".android" / "avd"
    if avd.is_dir():
        s = path_size(avd)
        if s > 2 * GB:
            ctx.info(f"Android emulator (AVD): {fmt(s)} — hapus AVD yang tidak dipakai lewat Device Manager")

    # ── JetBrains: cache versi lama aman dihapus; settings versi lama hanya di mode agresif ──
    for p in jetbrains_old_versions(HOME / "Library" / "Caches" / "JetBrains"):
        ctx.remove_path(p, f"JetBrains cache lama: {p.name}")
    for base in (HOME / "Library" / "Logs" / "JetBrains",):
        for p in jetbrains_old_versions(base):
            ctx.remove_path(p, f"JetBrains log lama: {p.name}")
    old_cfg = jetbrains_old_versions(HOME / "Library" / "Application Support" / "JetBrains")
    if old_cfg:
        size = sum(path_size(p) for p in old_cfg)
        jb_base = HOME / "Library" / "Application Support" / "JetBrains"
        kept = sorted(e.name for e in jb_base.iterdir()
                      if JB_RE.match(e.name) and e not in old_cfg)
        if ctx.aggressive:
            ctx.info(f"Versi JetBrains yang dipertahankan: {', '.join(kept)}")
        if ctx.aggressive and ctx.confirm(
                f"Hapus {len(old_cfg)} folder settings/plugin JetBrains versi lama ({fmt(size)})?"):
            for p in old_cfg:
                ctx.remove_path(p, f"JetBrains settings lama: {p.name}")
        elif not ctx.aggressive:
            ctx.info(f"JetBrains settings versi lama: {fmt(size)} (dihapus hanya di mode --aggressive)")

    # ── Package managers ──
    caches = HOME / "Library" / "Caches"
    ctx.run_tool(["pip3", "cache", "purge"], "Cache pip dibersihkan", [caches / "pip"])
    ctx.run_tool(["uv", "cache", "clean"], "Cache uv dibersihkan", [HOME / ".cache" / "uv"])
    ctx.run_tool(["conda", "clean", "-a", "-y"], "Cache conda dibersihkan")
    ctx.run_tool(["npm", "cache", "clean", "--force"], "Cache npm dibersihkan", [HOME / ".npm" / "_cacache"])
    ctx.run_tool(["yarn", "cache", "clean"], "Cache Yarn dibersihkan", [caches / "Yarn"])
    ctx.run_tool(["pnpm", "store", "prune"], "pnpm store di-prune", [HOME / "Library" / "pnpm" / "store"])
    ctx.run_tool(["bun", "pm", "cache", "rm"], "Cache Bun dibersihkan", [HOME / ".bun" / "install" / "cache"])
    ctx.run_tool(["pod", "cache", "clean", "--all"], "Cache CocoaPods dibersihkan", [caches / "CocoaPods"])
    ctx.run_tool(["go", "clean", "-cache"], "Go build cache dibersihkan", [caches / "go-build"])
    ctx.clear_dir_contents(HOME / ".cargo" / "registry" / "cache", "Cargo registry cache")
    if ctx.aggressive:
        ctx.run_tool(["go", "clean", "-modcache"], "Go module cache dibersihkan", [HOME / "go" / "pkg" / "mod"])
        if shutil.which("flutter"):
            ctx.run_tool(["flutter", "pub", "cache", "clean", "-f"], "Flutter pub cache dibersihkan")
        m2 = HOME / ".m2" / "repository"
        if m2.exists() and ctx.confirm(f"Hapus Maven repository ~/.m2 ({fmt(path_size(m2))})? Akan download ulang."):
            ctx.remove_path(m2, "Maven repository")

    # ── Homebrew ──
    if shutil.which("brew"):
        _, bc = run(["brew", "--cache"], timeout=30)
        ctx.run_tool(["brew", "cleanup", "--prune=all", "-s"], "Homebrew cleanup", [bc.strip()] if bc.strip() else ())
        if ctx.aggressive:
            ctx.run_tool(["brew", "autoremove"], "Homebrew: dependency tak terpakai dihapus")

    # ── Docker (volume TIDAK dihapus kecuali --docker-volumes) ──
    if shutil.which("docker"):
        rc, _ = run(["docker", "info"], timeout=15)
        if rc != 0:
            ctx.info("Docker tidak berjalan — dilewati")
        else:
            raw = HOME / "Library" / "Containers" / "com.docker.docker" / "Data" / "vms" / "0" / "data" / "Docker.raw"
            if raw.exists():
                ctx.info(f"Docker disk image: {fmt(path_size(raw))} terpakai")
            if ctx.dry_run:
                _, df = run(["docker", "system", "df"], timeout=60)
                for line in df.strip().splitlines():
                    ctx.info(f"[dry-run] {line}")
            else:
                cmd = ["docker", "system", "prune", "-f"]
                if ctx.aggressive and ctx.confirm("Hapus SEMUA image Docker yang tidak dipakai container (prune -a)?"):
                    cmd.append("-a")
                if ctx.args.docker_volumes and ctx.confirm(
                        f"{RED}Hapus volume Docker yang tidak terpakai? Data database lokal bisa hilang!{RESET}"):
                    cmd.append("--volumes")
                rc, out = run(cmd, timeout=900)
                m = re.search(r"Total reclaimed space:\s*(.+)", out)
                if rc == 0:
                    ctx.ok(f"Docker prune selesai ({m.group(1).strip() if m else '0B'} dibebaskan)")
                else:
                    ctx.warn(f"Docker prune gagal (kode {rc})")


# ─────────────────────────── Cleaner: Projects ───────────────────────────

def recent_activity(root, max_depth=3, max_entries=3000):
    """Waktu modifikasi terbaru di project (tanpa node_modules/.git), dibatasi agar cepat."""
    latest, count = 0.0, 0
    stack = [(str(root), 0)]
    while stack and count < max_entries:
        d, depth = stack.pop()
        try:
            with os.scandir(d) as it:
                for e in it:
                    if e.name in ("node_modules", ".git", ".venv", "venv"):
                        continue
                    count += 1
                    try:
                        st = e.stat(follow_symlinks=False)
                        latest = max(latest, st.st_mtime)
                        if depth < max_depth and stat.S_ISDIR(st.st_mode) and e.name not in PROJECT_WALK_SKIP:
                            stack.append((e.path, depth + 1))
                    except OSError:
                        pass
        except OSError:
            pass
    return latest


def clean_projects(ctx):
    ctx.category = CATEGORIES["projects"]
    stale_days = ctx.cfg["node_modules_stale_days_aggressive" if ctx.aggressive else "node_modules_stale_days"]
    ctx.step(f"Memindai Project (node_modules tidak aktif > {stale_days} hari)")
    now = time.time()
    node_stale, venv_stale, pycaches = [], [], []
    active = 0
    seen = set()
    for base in ctx.cfg["project_dirs"]:
        if not base.is_dir():
            continue
        for root, dirs, _ in os.walk(base):
            rp = Path(root)
            if rp in seen:
                dirs[:] = []
                continue
            seen.add(rp)
            if "node_modules" in dirs:
                idle = (now - recent_activity(rp)) / DAY
                if idle > stale_days:
                    node_stale.append((rp / "node_modules", idle))
                else:
                    active += 1
            for v in (".venv", "venv"):
                if v in dirs and (rp / v / "pyvenv.cfg").exists():
                    idle = (now - recent_activity(rp)) / DAY
                    if idle > ctx.cfg["venv_stale_days"]:
                        venv_stale.append((rp / v, idle))
            if "__pycache__" in dirs:
                pycaches.append(rp / "__pycache__")
            dirs[:] = [d for d in dirs if d not in PROJECT_WALK_SKIP
                       and d not in ("node_modules", ".venv", "venv") and not d.startswith(".")]

    if active:
        ctx.info(f"{active} node_modules di project aktif dibiarkan")
    if node_stale:
        sized = sorted(((p, idle, path_size(p)) for p, idle in node_stale), key=lambda x: -x[2])
        total = sum(s for _, _, s in sized)
        for p, idle, s in sized[:15]:
            ctx.info(f"{fmt(s):>9}  {p.parent}  {DIM}({idle:.0f} hari tidak aktif){RESET}")
        if len(sized) > 15:
            ctx.info(f"... dan {len(sized) - 15} lainnya")
        if ctx.confirm(f"Hapus {len(sized)} node_modules tidak aktif ({fmt(total)})? "
                       f"Bisa dipulihkan dengan `npm install`.", True):
            for p, _, _ in sized:
                ctx.remove_path(p, quiet=True)
            ctx.ok(f"node_modules tidak aktif: {ctx.size_tag(total)}")
    else:
        ctx.ok("Tidak ada node_modules tidak aktif.")

    if pycaches:
        total = sum(ctx.remove_path(p, quiet=True) for p in pycaches)
        ctx.ok(f"{len(pycaches)} folder __pycache__: {ctx.size_tag(total)}")

    if venv_stale:
        sized = [(p, idle, path_size(p)) for p, idle in venv_stale]
        total = sum(s for _, _, s in sized)
        for p, idle, s in sized[:10]:
            ctx.info(f"{fmt(s):>9}  {p}  {DIM}(venv, {idle:.0f} hari tidak aktif){RESET}")
        if ctx.aggressive and ctx.confirm(f"Hapus {len(sized)} virtualenv tidak aktif ({fmt(total)})?"):
            for p, _, _ in sized:
                ctx.remove_path(p, quiet=True)
            ctx.ok(f"virtualenv tidak aktif: {ctx.size_tag(total)}")
        elif not ctx.aggressive:
            ctx.info(f"virtualenv tidak aktif: {fmt(total)} (dihapus hanya di mode --aggressive)")


# ─────────────────────────── Cleaner: Browser ────────────────────────────

BROWSERS = {
    "Google Chrome": "Google/Chrome",
    "Microsoft Edge": "Microsoft Edge",
    "Brave Browser": "BraveSoftware/Brave-Browser",
    "Arc": "Arc/User Data",
    "Vivaldi": "Vivaldi",
    "Chromium": "Chromium",
    "Opera": "com.operasoftware.Opera",
}
BROWSER_CACHE_SUBDIRS = ("Service Worker/CacheStorage", "Code Cache", "GPUCache", "DawnCache",
                         "DawnGraphiteCache", "DawnWebGPUCache")


def clean_browsers(ctx):
    ctx.category = CATEGORIES["browser"]
    ctx.step("Membersihkan Cache Browser (Service Worker, Code & GPU cache)")
    any_found = False
    for proc, sub in BROWSERS.items():
        base = HOME / "Library" / "Application Support" / sub
        if not base.is_dir():
            continue
        any_found = True
        if is_process_running(proc):
            ctx.warn(f"{proc} sedang berjalan — tutup dulu untuk membersihkan cache-nya (dilewati)")
            continue
        profiles = [base / "Default"] + sorted(base.glob("Profile *"))
        total = 0
        for prof in profiles:
            for s in BROWSER_CACHE_SUBDIRS:
                total += ctx.remove_path(prof / s, quiet=True)
        for s in ("GrShaderCache", "ShaderCache", "component_crx_cache"):
            total += ctx.remove_path(base / s, quiet=True)
        if total:
            ctx.ok(f"{proc}: {ctx.size_tag(total)}")
        else:
            ctx.info(f"{proc}: sudah bersih")
    if not any_found:
        ctx.info("Tidak ada browser berbasis Chromium terdeteksi")
    ctx.info("Cache Safari/Firefox ikut dibersihkan di langkah Cache Sistem")


# ─────────────────────────── Cleaner: Sistem ─────────────────────────────

def clean_system(ctx):
    ctx.category = CATEGORIES["system"]
    ctx.step("Membersihkan Cache Sistem & Aplikasi")
    excludes = list(ctx.cfg["cache_excludes"])
    if not ctx.aggressive:
        excludes += ctx.cfg["cache_excludes_safe_mode"]
    caches = HOME / "Library" / "Caches"
    running = []
    try:
        for e in caches.iterdir():
            if e.name.lower() in ctx.running_ids:
                running.append(e.name)
    except OSError:
        pass
    if running:
        ctx.info(f"{len(running)} cache milik aplikasi yang sedang berjalan dilewati "
                 f"(tutup aplikasinya agar ikut dibersihkan)")
    ctx.clear_dir_contents(caches, "~/Library/Caches", excludes=excludes + running)
    ctx.clear_dir_contents(HOME / "Library" / "Logs", "~/Library/Logs", excludes=["CleanerMac", "JetBrains"])

    mail_dl = HOME / "Library" / "Containers" / "com.apple.mail" / "Data" / "Library" / "Mail Downloads"
    ctx.clear_dir_contents(mail_dl, "Mail Downloads (lampiran yang pernah dibuka)")

    if not ctx.dry_run:
        rc, _ = run(["qlmanage", "-r", "cache"], timeout=30)
        if rc == 0:
            ctx.ok("Cache thumbnail QuickLook di-reset")
    else:
        ctx.info("[dry-run] reset cache QuickLook (`qlmanage -r cache`)")
    if ctx.aggressive and ctx.confirm("Reset cache font user? (disarankan restart setelahnya)"):
        ctx.run_tool(["atsutil", "databases", "-removeUser"], "Cache font user di-reset")
        ctx.rec("Cache font di-reset — restart Mac agar efektif.")

    # Trash
    trash = HOME / ".Trash"
    try:
        tsize = path_size(trash) if any(trash.iterdir()) else 0
    except PermissionError:
        tsize = 0
        ctx.need_fda = True
        ctx.warn("Tidak bisa membaca Trash (butuh Full Disk Access untuk Terminal)")
    except OSError:
        tsize = 0
    if tsize:
        age = ctx.cfg["trash_min_age_days"]
        extra = f" (item > {age} hari)" if age else ""
        if ctx.confirm(f"Kosongkan Trash{extra} — {fmt(tsize)}?", True):
            ctx.clear_dir_contents(trash, "Trash", min_age_days=age, use_ctime=True)

    # Snapshot lokal Time Machine (sering jadi "System Data" puluhan GB)
    _, snaps = run(["tmutil", "listlocalsnapshots", "/"], timeout=30)
    tm = [l for l in snaps.splitlines() if "TimeMachine" in l]
    if tm:
        ctx.info(f"{len(tm)} snapshot lokal Time Machine ditemukan")
        if ctx.confirm(f"Hapus {len(tm)} snapshot lokal Time Machine? (backup di disk eksternal tetap aman)", True):
            ctx.admin_cmds.append(("Snapshot lokal Time Machine dihapus",
                                   "tmutil thinlocalsnapshots / 999999999999 4"))
    else:
        ctx.info("Tidak ada snapshot lokal Time Machine")


# ─────────────────────────── Laporan Storage ─────────────────────────────

def report_storage(ctx):
    ctx.category = CATEGORIES["reports"]
    ctx.step("Laporan Storage (tidak menghapus apa pun)")

    def report(path, label, hint):
        p = Path(path)
        if p.exists():
            s = path_size(p)
            if s > 200 * 1024 ** 2:
                ctx.info(f"{label}: {BOLD}{fmt(s)}{RESET} — {hint}")

    report(HOME / "Library/Application Support/MobileSync/Backup", "Backup iPhone/iPad",
           "kelola di Finder › iPhone › Manage Backups")
    report(HOME / "Library/Messages/Attachments", "Lampiran iMessage",
           "System Settings › General › Storage › Messages")
    report(HOME / "Library/Developer/Xcode/Archives", "Xcode Archives", "hapus build lama via Xcode Organizer")
    report(HOME / "Library/Developer/CoreSimulator/Devices", "Data Simulator iOS", "hapus simulator tak terpakai di Xcode")
    report(HOME / "Movies", "Folder Movies", "periksa file video besar")

    # File lama di Downloads
    dl = HOME / "Downloads"
    cutoff = time.time() - ctx.cfg["downloads_old_days"] * DAY
    old = []
    try:
        for e in dl.iterdir():
            if e.name.startswith("."):
                continue
            try:
                if last_activity(e.lstat()) < cutoff:
                    old.append((path_size(e), e))
            except OSError:
                pass
    except OSError:
        pass
    total = sum(s for s, _ in old)
    if old and total:
        old.sort(reverse=True)
        ctx.info(f"Downloads > {ctx.cfg['downloads_old_days']} hari: {BOLD}{fmt(total)}{RESET} ({len(old)} item). Terbesar:")
        for s, p in old[:5]:
            ctx._out(f"      {fmt(s):>9}  {p.name}")
        if total > GB:
            ctx.rec(f"~/Downloads berisi {fmt(total)} file lama — tinjau & hapus manual.")

    # File besar (via Spotlight, cepat)
    limit = int(ctx.cfg["large_file_gb"] * GB)
    rc, out = run(["mdfind", "-onlyin", str(HOME), f"kMDItemFSSize > {limit}"], timeout=60)
    big = []
    for line in out.splitlines():
        p = Path(line)
        if "/Library/" in line or not p.is_file():
            continue
        try:
            big.append((p.stat().st_blocks * 512, p))
        except OSError:
            pass
    if big:
        big.sort(reverse=True)
        ctx.info(f"File > {ctx.cfg['large_file_gb']} GB di home ({len(big)} file). Terbesar:")
        for s, p in big[:10]:
            ctx._out(f"      {fmt(s):>9}  {str(p).replace(str(HOME), '~')}")


# ─────────────────────────── Maintenance (admin) ─────────────────────────

LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
              "LaunchServices.framework/Support/lsregister")


def memory_free_pct():
    _, mp = run(["memory_pressure"], timeout=15)
    m = re.search(r"free percentage:\s*(\d+)%", mp)
    return int(m.group(1)) if m else None


def run_maintenance(ctx):
    ctx.category = "Maintenance"
    args = ctx.args
    if args.flush_dns:
        ctx.admin_cmds.append(("DNS cache di-flush", "dscacheutil -flushcache; killall -HUP mDNSResponder"))
    if args.purge:
        ctx.admin_cmds.append(("RAM file cache dilepaskan (purge)", "purge"))
    if args.reindex_spotlight:
        ctx.admin_cmds.append(("Index Spotlight dibangun ulang (berjalan di background)", "mdutil -E /"))
    want_ls = ctx.aggressive and os.path.exists(LSREGISTER)
    if not ctx.admin_cmds and not want_ls:
        return

    ctx.step("Maintenance Sistem")
    if want_ls and ctx.confirm("Rebuild database LaunchServices (memperbaiki menu 'Open With' dobel/lambat)?"):
        if ctx.dry_run:
            ctx.info("[dry-run] rebuild LaunchServices")
        else:
            # `-kill` tidak didukung lagi di macOS terbaru; `-r -f` memaksa registrasi ulang
            rc, _ = run([LSREGISTER, "-r", "-f", "-domain", "local", "-domain", "system", "-domain", "user"],
                        timeout=300)
            (ctx.ok if rc == 0 else ctx.warn)("LaunchServices di-rebuild" if rc == 0 else "Rebuild LaunchServices gagal")

    if not ctx.admin_cmds:
        return
    if ctx.dry_run:
        for desc, cmd in ctx.admin_cmds:
            ctx.info(f"[dry-run] {desc}: `{cmd}` (butuh password admin)")
        return

    before = memory_free_pct() if args.purge else None
    script = "; ".join(cmd for _, cmd in ctx.admin_cmds)
    ctx.info("Meminta izin administrator (Touch ID / password)...")
    rc, out = run(["osascript", "-e", f'do shell script "{script}" with administrator privileges'], timeout=900)
    if rc == 0:
        for desc, _ in ctx.admin_cmds:
            ctx.ok(desc)
        if before is not None:
            after = memory_free_pct()
            if after is not None:
                ctx.info(f"Memori bebas: {before}% → {after}%")
    else:
        ctx.warn("Tugas administrator dilewati/dibatalkan.")
        ctx.log(out[-500:])


def apply_ui_light(ctx):
    ctx.step("Optimasi Tampilan (Reduce Transparency & Reduce Motion)")
    for key in ("reduceTransparency", "reduceMotion"):
        if ctx.dry_run:
            ctx.info(f"[dry-run] defaults write com.apple.universalaccess {key} -bool true")
            continue
        rc, _ = run(["defaults", "write", "com.apple.universalaccess", key, "-bool", "true"], timeout=15)
        if rc == 0:
            ctx.ok(f"{key} diaktifkan")
        else:
            ctx.warn(f"Gagal mengubah {key} — aktifkan manual di System Settings › Accessibility › Display")


# ─────────────────────────────── Ringkasan ───────────────────────────────

def summary(ctx, disk_before):
    ctx.step("Ringkasan")
    total = sum(ctx.freed.values())
    if ctx.freed:
        for cat, n in sorted(ctx.freed.items(), key=lambda x: -x[1]):
            if n:
                ctx._out(f"    {cat:<32} {fmt(n):>10}")
        ctx._out(f"    {BOLD}{'TOTAL' + (' (estimasi)' if ctx.dry_run else ''):<32} {fmt(total):>10}{RESET}")
    if not ctx.dry_run:
        du = disk_stats()
        ctx.info(f"Ruang kosong disk: {fmt(disk_before.free)} → {BOLD}{fmt(du.free)}{RESET}")
        ctx.info(f"{DIM}(APFS kadang butuh beberapa menit untuk memperbarui ruang 'purgeable'){RESET}")
    if ctx.need_fda:
        ctx.rec("Beberapa folder dilewati karena izin. Beri Full Disk Access: System Settings › "
                "Privacy & Security › Full Disk Access › aktifkan Terminal.")
    if ctx.recs:
        print(f"\n  {BOLD}Rekomendasi:{RESET}")
        for r in ctx.recs:
            ctx._out(f"    {YELLOW}→{RESET} {r}")
    ctx.info(f"Log: {ctx.log_path}")


# ─────────────────────────────── CLI / Menu ──────────────────────────────

def parse_args():
    ap = argparse.ArgumentParser(description="Pembersih cache/storage & booster performa macOS")
    ap.add_argument("--dry-run", action="store_true", help="preview saja, tidak menghapus apa pun")
    ap.add_argument("-y", "--yes", action="store_true", help="setujui semua konfirmasi otomatis")
    ap.add_argument("--aggressive", "--aggresive", dest="aggressive", action="store_true",
                    help="pembersihan lebih dalam (Gradle, Maven, Go mod, dll)")
    ap.add_argument("--only", help=f"kategori dipisah koma: {','.join(CATEGORIES)}")
    ap.add_argument("--health", action="store_true", help="health check & audit startup saja")
    ap.add_argument("--purge", action="store_true", help="jalankan `purge` RAM (butuh admin, biasanya tidak perlu)")
    ap.add_argument("--flush-dns", action="store_true", help="flush DNS cache (butuh admin)")
    ap.add_argument("--reindex-spotlight", action="store_true", help="bangun ulang index Spotlight (butuh admin)")
    ap.add_argument("--docker-volumes", action="store_true", help="ikut hapus volume Docker tak terpakai (BERISIKO)")
    ap.add_argument("--ui-light", action="store_true", help="aktifkan Reduce Transparency & Reduce Motion")
    ap.add_argument("--init-config", action="store_true", help=f"buat config default di {CONFIG_PATH}")
    return ap.parse_args()


def ask_yes(q, default=False):
    hint = "Y/n" if default else "y/N"
    try:
        ans = input(f"  {CYAN}?{RESET} {q} [{hint}] ").strip().lower()
    except EOFError:
        return default
    return default if not ans else ans in ("y", "ya", "yes")


def interactive_menu(args):
    print(f"""
  {BOLD}Pilih mode:{RESET}
    1) Health check & audit startup  {DIM}(tidak menghapus apa pun){RESET}
    2) Preview pembersihan           {DIM}(dry-run){RESET}
    3) Pembersihan aman              {GREEN}(direkomendasikan){RESET}
    4) Pembersihan agresif           {DIM}(Gradle, Maven, Go mod, settings IDE lama, dll){RESET}
    5) Optimasi tampilan             {DIM}(Reduce Transparency & Motion){RESET}
    0) Keluar""")
    try:
        choice = input(f"\n  {CYAN}?{RESET} Pilihan [3]: ").strip() or "3"
    except EOFError:
        choice = "0"
    if choice == "1":
        args.health = True
    elif choice == "2":
        args.dry_run = True
    elif choice == "4":
        args.aggressive = True
    elif choice == "5":
        args.ui_light = True
        args.only = "none"
    elif choice != "3":
        sys.exit(0)
    if choice in ("3", "4"):
        args.flush_dns = ask_yes("Flush DNS cache? (butuh password admin)")
        args.purge = ask_yes("Purge RAM? (biasanya tidak perlu — macOS mengelola RAM sendiri)")


def main():
    args = parse_args()
    interactive_launch = len(sys.argv) == 1 and sys.stdin.isatty()

    if os.geteuid() == 0:
        print(f"{RED}Jangan jalankan dengan sudo — script akan meminta izin admin sendiri bila perlu.{RESET}")
        sys.exit(1)
    if args.init_config:
        if CONFIG_PATH.exists():
            print(f"Config sudah ada: {CONFIG_PATH}")
        else:
            CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
            CONFIG_PATH.write_text(json.dumps(DEFAULT_CONFIG, indent=2), encoding="utf-8")
            print(f"Config dibuat: {CONFIG_PATH}")
        return

    print(f"{CYAN}==================================================")
    print("      CleanerMac — Cache, Storage & Performance    ")
    print(f"=================================================={RESET}")
    if interactive_launch:
        interactive_menu(args)

    ctx = Ctx(args, load_config())
    mode = "HEALTH CHECK" if args.health else ("DRY-RUN" if args.dry_run else
                                              ("AGRESIF" if args.aggressive else "AMAN"))
    ctx._out(f"  Mode: {BOLD}{mode}{RESET}")

    if args.only and args.only != "none":
        cats = [c.strip() for c in args.only.split(",") if c.strip()]
        unknown = [c for c in cats if c not in CATEGORIES]
        if unknown:
            print(f"{RED}Kategori tidak dikenal: {', '.join(unknown)}. Pilihan: {', '.join(CATEGORIES)}{RESET}")
            sys.exit(2)
    elif args.only == "none":
        cats = []
    elif args.health:
        cats = ["startup", "reports"]
    else:
        cats = list(CATEGORIES)

    disk_before = disk_stats()
    tasks = [("startup", audit_startup), ("dev", clean_dev), ("projects", clean_projects),
             ("browser", clean_browsers), ("system", clean_system), ("reports", report_storage)]
    try:
        if args.ui_light:
            apply_ui_light(ctx)
        if args.only != "none":
            health_check(ctx)
        for key, fn in tasks:
            if key in cats:
                fn(ctx)
        if not args.health:
            run_maintenance(ctx)
    except KeyboardInterrupt:
        print()
        ctx.warn("Dibatalkan oleh pengguna.")

    summary(ctx, disk_before)
    done = "Preview selesai — jalankan tanpa --dry-run untuk membersihkan." if args.dry_run else "Selesai!"
    print(f"\n{GREEN}✔ {done}{RESET}")
    if interactive_launch:
        try:
            input("\nTekan [Enter] untuk menutup...")
        except EOFError:
            pass


if __name__ == "__main__":
    main()
