#!/usr/bin/env bash
#
# install-tempbase-wine.sh - Linux installer for tempbase 2
#
# Turns the Windows setup file of tempbase 2 into a working program under Wine,
# including a USB fix for the TempMate logger.
# Tested on Linux Mint 22 / Ubuntu 24.04 (apt, WineHQ repository).
#
# Usage:
#   ./install-tempbase-wine.sh "/path/to/tempbase 2 V3.1.2.exe"   # first install
#   ./install-tempbase-wine.sh                    # repair (file not needed if
#                                                  # tempbase 2 is already installed)
#   ./install-tempbase-wine.sh --check            # only check the current state
#
# Options:
#   --yes          Answer all prompts with "yes"
#   --no-apt       Do not touch system packages/udev/groups (only prefix and program)
#   --check        Install nothing, only check the installation
# Environment variables:
#   WINEPREFIX     Wine prefix (default: ~/.wine)
#   XDG_DATA_HOME  Location for menu entries and helper files (default: ~/.local/share)
#
# What the script does:
#   1. System packages: i386 architecture, winbind, gcc etc.; WineHQ repository;
#      winehq-devel (the stable branch 11.0 has a USB bug, EIO on read)
#   2. udev rule and group "plugdev", so that the regular user may access the
#      USB logger (04d8:0015)
#   3. fresh 64-bit prefix (an existing one is moved aside), wine-mono is
#      downloaded beforehand and installed silently (no Mono dialog)
#   4. silent installation of tempbase 2
#   5. USB fix (background see below): patch DL.exe, build HID shim,
#      launcher with automatic patch check on every start,
#      redirect Start Menu AND desktop entries to it
#   6. final check
#
# When called without an installer file and tempbase 2 is already installed, only
# steps 5+6 are repeated - this is the recommended way to re-apply the fix after a
# tempbase self-update (see item d below).
#
# Background of the USB fix ("Device disconnected"):
#   a) DL.exe opens the logger with FILE_FLAG_OVERLAPPED, but reads through a
#      synchronous .NET FileStream (Wine Mono). If a read hits a response that
#      has not been delivered yet, it gets ERROR_IO_PENDING (997). tempbase
#      silently catches the exception and aborts the connection setup after
#      4 of 31 packets. -> DL.exe is patched in one place
#      (constant 0x40000000 -> 0). The original is kept as DL.exe.orig.
#   b) The logger does not answer requests that follow each other closer than
#      about 300 ms (tempbase sends every 80 ms). -> LD_PRELOAD shim.
#   c) tempbase updates itself and replaces DL.exe in the process. The launcher
#      (tempbase-start.sh) therefore checks on every start whether the patch is
#      in place and re-patches if needed. If the byte pattern no longer matches,
#      it changes nothing, shows a message and starts tempbase anyway.
#      Log: <XDG_DATA_HOME>/tempbase-shim/start.log
#   d) For this, the self-update downloads a FULL, non-silent setup and runs it
#      without silent parameters (unlike the silent first install done by this
#      script). Every time, this setup creates a new shortcut on the Windows
#      "Desktop". Wine turns that into a SEPARATE, second .desktop file directly
#      on the real desktop (independent of XDG_DATA_HOME) with a PLAIN "wine ..."
#      call, without our launcher. Double-clicking this (new) desktop icon thus
#      bypasses both the USB patch and the HID shim WITHOUT any error message
#      (the launcher is never called) - just "Device disconnected" as before.
#      The Windows Start Menu entry itself is demonstrably NOT affected (tested
#      with a real version update): Wine recognizes it as already existing and
#      does not rewrite it.
#      -> This script also redirects an existing desktop icon to the launcher
#      (step 5) and then makes BOTH shortcuts read-only (chmod 555, i.e.
#      executable but writable by nobody - GNOME/Cinnamon/Nemo need the X bit to
#      treat the file as launchable/trusted at all; the missing write permission
#      is what stops Wine from overwriting it). Wine demonstrably overwrites an
#      existing .desktop file via open+truncate, not via unlink+rename, and
#      therefore respects missing write permissions (deleting it later when
#      uninstalling still works, since unlink only needs directory permissions).
#      Re-running this script after an update is thus only an additional
#      safety net, not a requirement.

set -euo pipefail

# ---------------------------------------------------------------- Settings
WINEPREFIX="${WINEPREFIX:-$HOME/.wine}"
export WINEPREFIX
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS_DIR="$DATA_HOME/applications"
SHIM_DIR="$DATA_HOME/tempbase-shim"
# For EVERY Windows shortcut located under "...\Desktop", Wine additionally creates
# its own .desktop file on the real desktop (via xdg-user-dir, INDEPENDENT of
# XDG_DATA_HOME). tempbase creates such a shortcut anew on every self-update (full,
# non-silent setup) - this second location must be taken into account when patching
# the launchers, otherwise double-clicking the desktop icon after an update points
# to unpatched tempbase again.
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
[ -n "$DESKTOP_DIR" ] || DESKTOP_DIR="$HOME/Desktop"
# Some setups (e.g. desktop as a symlink to a cloud sync folder) have a symbolic link
# here. "find" does NOT follow a symlink given as start path by default and would
# then find nothing in it - so resolve it to the real path once here.
DESKTOP_DIR="$(readlink -f "$DESKTOP_DIR" 2>/dev/null || echo "$DESKTOP_DIR")"
WINE=/opt/wine-devel/bin/wine
WINESERVER=/opt/wine-devel/bin/wineserver
TB_DIR="$WINEPREFIX/drive_c/tempbase 2"
UDEV_RULE=/etc/udev/rules.d/99-tempmate-hidraw.rules
TEMPMATE_VID="04d8"
TEMPMATE_PID="0015"
# Uninstall entries are left alone ("entfernen": German-localized entries).
UNINSTALL_FILTER=(-e entfernen -e uninstall -e remove -e deinstall)

YES=0; NO_APT=0; CHECK_ONLY=0; INSTALLER=""

info() { echo "==> $*"; }
warn() { echo "    Warning: $*" >&2; }
die()  { echo "Error: $*" >&2; exit 1; }

ask() {   # ask "text"  -> 0 on yes
    [ "$YES" = 1 ] && return 0
    local a; read -r -p "$1 [y/N] " a
    case "$a" in y|Y|yes|Yes|YES) return 0;; *) return 1;; esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        # The German option names of earlier versions are still accepted.
        --yes|--ja) YES=1;;
        --no-apt|--ohne-apt) NO_APT=1;;
        --check|--pruefen) CHECK_ONLY=1;;
        -h|--help) sed -n '2,/^$/p' "$0"; exit 0;;
        -*) die "Unknown option: $1 (see --help)";;
        *) [ -z "$INSTALLER" ] || die "Specify only one installer file."; INSTALLER="$1";;
    esac
    shift
done

# ------------------------------------------------------- Final check
check_install() {
    local fail=0
    ok()   { printf '  [OK]      %s\n' "$*"; }
    bad()  { printf '  [MISSING] %s\n' "$*"; fail=1; }
    note() { printf '  [NOTE]    %s\n' "$*"; }

    info "Checking the installation"
    if [ -x "$WINE" ]; then ok "wine-devel: $("$WINE" --version 2>/dev/null)"; else bad "wine-devel ($WINE) is missing"; fi
    if [ -f "$WINEPREFIX/drive_c/windows/mono/mono-2.0/bin/libmono-2.0-x86.dll" ]; then
        ok "wine-mono in prefix"; else bad "wine-mono is missing in prefix $WINEPREFIX"; fi
    if [ -f "$TB_DIR/DL.exe" ]; then
        ok "tempbase 2: $TB_DIR/DL.exe"
        if [ -f "$SHIM_DIR/patch-dl.py" ]; then
            local tmp out rc; tmp=$(mktemp); cp "$TB_DIR/DL.exe" "$tmp"
            out=$(python3 "$SHIM_DIR/patch-dl.py" "$tmp" 2>&1) && rc=0 || rc=$?
            rm -f "$tmp" "$tmp.orig"
            if [ "$rc" = 0 ] && [ "$out" = "already patched" ]; then ok "USB patch in DL.exe is active"
            elif [ "$rc" = 0 ]; then note "DL.exe is not patched yet; the launcher will do this on the next start"
            else bad "USB patch cannot be applied: $out"; fi
        else bad "patch-dl.py is missing in $SHIM_DIR"; fi
    else bad "tempbase 2 not found ($TB_DIR/DL.exe)"; fi
    if [ -s "$SHIM_DIR/hidraw-delay.so" ]; then ok "HID shim built"; else bad "HID shim is missing"; fi
    if [ -x "$SHIM_DIR/tempbase-start.sh" ]; then ok "launcher present"; else bad "launcher is missing"; fi
    local n=0 z
    while IFS= read -r z; do
        [ -n "$z" ] || continue
        if grep -q "tempbase-start.sh" "$z"; then n=$((n+1)); else bad "Menu entry without launcher: $z"; fi
    done < <(find "$APPS_DIR" -iname "*tempbase*.desktop" 2>/dev/null | grep -vi "${UNINSTALL_FILTER[@]}" || true)
    if [ "$n" -gt 0 ]; then ok "Start Menu entries ($n) use the launcher"; else bad "no Start Menu entry with launcher"; fi
    local d=0
    while IFS= read -r z; do
        [ -n "$z" ] || continue
        if grep -q "tempbase-start.sh" "$z"; then d=$((d+1)); else bad "Desktop icon without launcher (points to unpatched tempbase): $z"; fi
    done < <(find "$DESKTOP_DIR" -maxdepth 1 -iname "*tempbase*.desktop" 2>/dev/null | grep -vi "${UNINSTALL_FILTER[@]}" || true)
    [ "$d" -gt 0 ] && ok "Desktop icons ($d) use the launcher"
    if [ -f "$UDEV_RULE" ]; then ok "udev rule present"; else bad "udev rule is missing ($UDEV_RULE)"; fi
    if id -nG "${USER:-$(id -un)}" | grep -qw plugdev; then ok "user is in group plugdev"
    else bad "user is not in group plugdev (after changing this: log out and back in)"; fi
    local h found=0
    for h in /sys/class/hidraw/hidraw*; do
        [ -e "$h" ] || continue
        if readlink -f "$h/device" | grep -qi "0003:0*${TEMPMATE_VID}:0*${TEMPMATE_PID}"; then
            found=1; local node="/dev/$(basename "$h")"
            if [ -r "$node" ] && [ -w "$node" ]; then ok "logger plugged in, $node is accessible"
            else bad "logger found ($node), but no access (group/udev/replug)"; fi
        fi
    done
    [ "$found" = 1 ] || note "No TempMate logger plugged in (cannot check)"
    echo
    if [ "$fail" = 0 ]; then echo "Result: everything is fine."; else echo "Result: there are open issues (see above)."; fi
    return "$fail"
}

if [ "$CHECK_ONLY" = 1 ]; then check_install; exit $?; fi

# ------------------------------------------------------------------- Pre-checks
[ "$(id -u)" != 0 ] || die "Please do NOT run as root (the script uses sudo when needed)."
if [ -z "$INSTALLER" ] && [ ! -f "$TB_DIR/DL.exe" ]; then
    echo "Usage: $0 [--yes] [--no-apt] \"/path/to/tempbase-installer.exe\"" >&2
    echo "(The installer file is only needed the very first time; tempbase 2 is not yet" >&2
    echo " installed in $WINEPREFIX.)" >&2
    exit 1
fi
if [ -n "$INSTALLER" ]; then
    [ -f "$INSTALLER" ] || die "Installer file not found: $INSTALLER"
    [ "$(head -c 2 "$INSTALLER")" = "MZ" ] || die "This is not a Windows executable (.exe): $INSTALLER"
    INSTALLER="$(readlink -f "$INSTALLER")"
elif [ -f "$TB_DIR/DL.exe" ]; then
    info "No installer file given, tempbase 2 is already installed - repairing only"
    info "(USB patch, HID shim, launcher, menu/desktop entries)."
fi
if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    warn "No graphical session detected (DISPLAY is empty). The installation needs one."
fi

# ------------------------------------------------- 1. System packages and WineHQ
if [ "$NO_APT" = 1 ]; then
    info "1/6: System packages skipped (--no-apt)"
    [ -x "$WINE" ] || die "$WINE is missing. Run again without --no-apt."
else
    command -v apt >/dev/null 2>&1 || die "Only intended for Debian/Ubuntu/Linux Mint (apt)."
    . /etc/os-release
    CODENAME="${UBUNTU_CODENAME:-}"
    [ -n "$CODENAME" ] || { [ "${ID:-}" = ubuntu ] && CODENAME="${VERSION_CODENAME:-}"; }
    [ -n "$CODENAME" ] || die "Cannot determine Ubuntu codename (/etc/os-release). See https://wiki.winehq.org/Ubuntu"

    info "1/6: System packages (i386, winbind, tools) and WineHQ repository (codename: $CODENAME)"
    sudo dpkg --add-architecture i386
    sudo apt update
    sudo apt install -y winbind wget ca-certificates gnupg python3 build-essential
    sudo mkdir -pm755 /etc/apt/keyrings
    sudo wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
    sudo wget -qNP /etc/apt/sources.list.d/ \
        "https://dl.winehq.org/wine-builds/ubuntu/dists/${CODENAME}/winehq-${CODENAME}.sources" \
        || die "No WineHQ repository found for '$CODENAME'."
    sudo apt update
    if [ -x "$WINE" ]; then
        echo "    wine-devel is already installed."
    else
        sudo apt install -y --install-recommends winehq-devel
    fi
    sudo apt install -y libegl1:i386 libegl-mesa0:i386 || warn "Could not install 32-bit EGL libraries (usually harmless)."
    [ -x "$WINE" ] || die "$WINE is missing after installing winehq-devel."

    info "2/6: USB access for the TempMate logger (udev rule, group plugdev)"
    RULE_LINE="SUBSYSTEM==\"hidraw\", ATTRS{idVendor}==\"${TEMPMATE_VID}\", ATTRS{idProduct}==\"${TEMPMATE_PID}\", MODE=\"0660\", GROUP=\"plugdev\", TAG+=\"uaccess\""
    if [ -f "$UDEV_RULE" ] && grep -qF "$RULE_LINE" "$UDEV_RULE"; then
        echo "    Rule already exists."
    else
        echo "$RULE_LINE" | sudo tee "$UDEV_RULE" >/dev/null
        sudo udevadm control --reload-rules
        sudo udevadm trigger --subsystem-match=hidraw
        echo "    Rule installed."
    fi
    if id -nG "$USER" | grep -qw plugdev; then
        echo "    $USER is already in group plugdev."
    else
        sudo usermod -aG plugdev "$USER"
        NEED_RELOGIN=1
        echo "    Added $USER to group plugdev (you need to log in again, see the end)."
    fi
fi
command -v python3 >/dev/null 2>&1 || die "python3 is missing."

# ------------------------------------------------------ 3. Prefix and Mono
if [ -f "$TB_DIR/DL.exe" ]; then
    info "3/6 + 4/6: tempbase 2 is already installed in prefix $WINEPREFIX; skipping prefix and setup"
else
    info "3/6: Creating Wine prefix: $WINEPREFIX"
    "$WINESERVER" -k 2>/dev/null || true
    if [ -e "$WINEPREFIX" ]; then
        BACKUP="${WINEPREFIX}-backup-$(date +%Y%m%d-%H%M%S)"
        echo "    A prefix already exists (without tempbase 2)."
        ask "    Move it to $BACKUP and create a fresh prefix?" || die "Aborted. Try again with a different WINEPREFIX."
        mv "$WINEPREFIX" "$BACKUP"
        echo "    Backed up to: $BACKUP"
    fi

    # Wine Mono: the version is stored in appwiz.cpl; download it beforehand so that Wine shows no dialog
    MONO_MSI=$(python3 - <<'PYX' 2>/dev/null || true
import re
try:
    d = open("/opt/wine-devel/lib/wine/x86_64-windows/appwiz.cpl", "rb").read()
    m = re.search(rb"(?:w\x00i\x00n\x00e\x00-\x00m\x00o\x00n\x00o\x00-\x00(?:[0-9.]\x00)+-\x00x\x008\x006\x00\.\x00m\x00s\x00i\x00)", d)
    print(m.group(0).decode("utf-16le") if m else "")
except OSError:
    print("")
PYX
)
    MONO_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/wine"
    if [ -n "$MONO_MSI" ]; then
        MONO_VER="${MONO_MSI#wine-mono-}"; MONO_VER="${MONO_VER%-x86.msi}"
        mkdir -p "$MONO_CACHE"
        if [ ! -s "$MONO_CACHE/$MONO_MSI" ]; then
            echo "    Downloading $MONO_MSI ..."
            wget -q -O "$MONO_CACHE/$MONO_MSI.part" "https://dl.winehq.org/wine/wine-mono/$MONO_VER/$MONO_MSI" \
                && mv "$MONO_CACHE/$MONO_MSI.part" "$MONO_CACHE/$MONO_MSI" \
                || { rm -f "$MONO_CACHE/$MONO_MSI.part"; warn "Mono download failed."; MONO_MSI=""; }
        fi
    else
        warn "Cannot determine the Mono version."
    fi

    # Suppress Mono/Gecko dialogs, then install Mono silently
    env WINEARCH=win64 WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" "$WINE" wineboot --init 2>&1 | grep -v -e MESA -e ELFCLASS || true
    "$WINESERVER" -w
    if [ -n "$MONO_MSI" ] && [ -s "$MONO_CACHE/$MONO_MSI" ]; then
        echo "    Installing Wine Mono $MONO_VER ..."
        env WINEDEBUG=-all "$WINE" msiexec /i "$(env WINEDEBUG=-all "$WINE" winepath -w "$MONO_CACHE/$MONO_MSI" 2>/dev/null | tr -d '\r')" /qn 2>&1 | grep -v -e MESA -e ELFCLASS || true
        "$WINESERVER" -w
    fi
    [ -f "$WINEPREFIX/drive_c/windows/mono/mono-2.0/bin/libmono-2.0-x86.dll" ] \
        || warn "Wine Mono is missing in the prefix. On first start, confirm the Mono dialog with 'Install' if it appears."

    info "4/6: Installing tempbase 2 (silently)"
    env WINEDEBUG=-all "$WINE" "$INSTALLER" /SILENT /SUPPRESSMSGBOXES /NORESTART 2>&1 | grep -v -e MESA -e ELFCLASS || true
    "$WINESERVER" -w
    if [ ! -f "$TB_DIR/DL.exe" ]; then
        FOUND=$(find "$WINEPREFIX/drive_c" -maxdepth 4 -name DL.exe 2>/dev/null | head -1 || true)
        die "DL.exe not found in $TB_DIR${FOUND:+ (found: $FOUND; the USB fix expects 'C:\\tempbase 2')}. Did the installation fail?"
    fi
    echo "    tempbase 2 installed: $TB_DIR"
fi

# ---------------------------------------------------------- 5. USB fix
info "5/6: USB fix (DL.exe patch, HID shim, launcher, menu entries)"
mkdir -p "$SHIM_DIR"

cat > "$SHIM_DIR/patch-dl.py" <<'PYEOF'
#!/usr/bin/env python3
"""Removes FILE_FLAG_OVERLAPPED from tempbase 2 (DL.exe), see install-tempbase-wine.sh.

Exit codes: 0 = patched or already patched, 2 = pattern not found (exactly once),
            1 = file missing/error. With exit code != 0 nothing is changed.
"""
import os, re, shutil, sys

# IL: ldc.i4 0xC0000000 / ldc.i4.3 / ldsfld IntPtr.Zero / ldc.i4.3 /
#     ldc.i4 0x40000000 (FILE_FLAG_OVERLAPPED) / ldc.i4.0 / call CreateFile
PAT = rb"\x20\x00\x00\x00\xc0\x19\x7e....\x19\x20\x00\x00\x00\x40\x16\x28"
PAT_DONE = rb"\x20\x00\x00\x00\xc0\x19\x7e....\x19\x16\x00\x00\x00\x00\x16\x28"

def main():
    if len(sys.argv) != 2:
        print("Usage: patch-dl.py <DL.exe>", file=sys.stderr); return 1
    p = sys.argv[1]
    try:
        d = bytearray(open(p, "rb").read())
    except OSError as e:
        print("Cannot read DL.exe: %s" % e, file=sys.stderr); return 1
    if re.search(PAT_DONE, bytes(d), re.S):
        print("already patched"); return 0
    ms = list(re.finditer(PAT, bytes(d), re.S))
    if len(ms) != 1:
        print("pattern found %d times in DL.exe (expected: 1). Probably a different "
              "tempbase version; nothing changed." % len(ms), file=sys.stderr)
        return 2
    try:
        shutil.copy2(p, p + ".orig")          # back up the current, unpatched version
        o = ms[0].start() + 12
        d[o:o + 5] = b"\x16\x00\x00\x00\x00"  # ldc.i4.0 + 4x nop
        open(p, "wb").write(d)
    except OSError as e:
        print("Write failed: %s" % e, file=sys.stderr); return 1
    print("patched (offset 0x%x), original: %s.orig" % (o, p))
    return 0

if __name__ == "__main__":
    sys.exit(main())
PYEOF
chmod +x "$SHIM_DIR/patch-dl.py"
python3 "$SHIM_DIR/patch-dl.py" "$TB_DIR/DL.exe" | sed 's/^/    DL.exe: /' \
    || warn "Could not patch DL.exe (different tempbase version?). See $SHIM_DIR/start.log after the first start."

cat > "$SHIM_DIR/hidraw-delay.c" <<'CEOF'
/*
 * LD_PRELOAD shim for tempbase 2 under Wine.
 * The TempMate logger (USB 04d8:0015) does not answer requests that follow each
 * other too closely (tempbase sends every 80 ms). On write() to /dev/hidraw*, this
 * shim keeps at least TEMPBASE_HID_DELAY_MS (default 300) between two writes.
 * With TEMPBASE_HID_ALL=1 this applies to every request; without it only after
 * requests for memory block 0x60.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct timespec last_write;
static int have_last, last_was_slow;

static long delay_ms(void)
{
    static long d = -1;
    if (d < 0) { const char *e = getenv("TEMPBASE_HID_DELAY_MS"); d = e ? atol(e) : 300; }
    return d;
}

static int is_hidraw(int fd)
{
    char link[64], path[64];
    ssize_t n;
    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    n = readlink(link, path, sizeof(path) - 1);
    if (n <= 0) return 0;
    path[n] = 0;
    return strncmp(path, "/dev/hidraw", 11) == 0;
}

static void wait_spacing(void)
{
    struct timespec now, want;
    long d = delay_ms();
    if (!have_last || d <= 0) return;
    want = last_write;
    want.tv_sec += d / 1000;
    want.tv_nsec += (d % 1000) * 1000000L;
    if (want.tv_nsec >= 1000000000L) { want.tv_sec++; want.tv_nsec -= 1000000000L; }
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (now.tv_sec < want.tv_sec || (now.tv_sec == want.tv_sec && now.tv_nsec < want.tv_nsec))
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &want, NULL);
}

static int is_slow_request(const void *buf, size_t count)
{
    const unsigned char *b = buf;
    if (getenv("TEMPBASE_HID_ALL")) return 1;
    return count >= 12 && b[0] == 0x33 && b[1] == 0xcc && b[3] == 0x0c && b[8] == 0x60;
}

ssize_t write(int fd, const void *buf, size_t count)
{
    static ssize_t (*real_write)(int, const void *, size_t);
    ssize_t r;
    if (!real_write) real_write = dlsym(RTLD_NEXT, "write");
    if (!is_hidraw(fd)) return real_write(fd, buf, count);
    pthread_mutex_lock(&lock);
    if (last_was_slow) wait_spacing();
    r = real_write(fd, buf, count);
    clock_gettime(CLOCK_MONOTONIC, &last_write);
    have_last = 1;
    last_was_slow = is_slow_request(buf, count);
    pthread_mutex_unlock(&lock);
    return r;
}
CEOF
command -v gcc >/dev/null 2>&1 || die "gcc is missing (install build-essential or run without --no-apt)."
gcc -O2 -shared -fPIC -o "$SHIM_DIR/hidraw-delay.so" "$SHIM_DIR/hidraw-delay.c" -ldl -lpthread
echo "    HID shim built: $SHIM_DIR/hidraw-delay.so"

cat > "$SHIM_DIR/tempbase-start.sh" <<'SHEOF'
#!/usr/bin/env bash
# Launcher for tempbase 2 under Wine: checks/patches DL.exe, sets up the HID shim, starts tempbase.
DIR="$(dirname "$(readlink -f "$0")")"
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine}"
export LD_PRELOAD="$DIR/hidraw-delay.so"
export TEMPBASE_HID_ALL=1
WINE="${TEMPBASE_WINE:-/opt/wine-devel/bin/wine}"
LOG="$DIR/start.log"

out=$(python3 "$DIR/patch-dl.py" "$WINEPREFIX/drive_c/tempbase 2/DL.exe" 2>&1)
rc=$?
echo "$(date '+%F %T') patch-dl rc=$rc: $out" >> "$LOG"
if [ "$rc" -ne 0 ]; then
    msg="tempbase 2: The USB fix could not be applied ($out). tempbase was probably updated. \"Device disconnected\" is then likely. Instructions for a Claude session: $DIR/REPAIR.md (log: $LOG)."
    if command -v notify-send >/dev/null 2>&1; then notify-send -u critical "tempbase 2" "$msg"
    elif command -v zenity >/dev/null 2>&1; then zenity --warning --text="$msg" &
    else echo "$msg" >&2; fi
fi
exec "$WINE" "C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\tempbase 2\\tempbase 2.lnk" "$@"
SHEOF
chmod +x "$SHIM_DIR/tempbase-start.sh"

rm -f "$SHIM_DIR/REPARATUR.md"   # former (German) name of REPAIR.md
cat > "$SHIM_DIR/REPAIR.md" <<'MDEOF'
# tempbase 2 under Wine: USB patch fails - instructions for a Claude session

This file is a prompt/handover text. It lives in `<XDG_DATA_HOME>/tempbase-shim/REPAIR.md`
(default `~/.local/share/tempbase-shim/`). The user hands it to a new Claude Code session.
Communicate with the user in their own language.

## Situation

tempbase 2 (.NET program `DL.exe`, vendor TempMate) is run under Wine (wine-devel, `/opt/wine-devel`)
via `install-tempbase-wine.sh`. The launcher `tempbase-start.sh` calls `patch-dl.py` on every start.
The patch tool did not find the byte pattern in `DL.exe` (exactly once). Most likely tempbase updated
itself to a new version via its self-update (`setup.exe`). Without the patch, tempbase shows
"Device disconnected" on every click and the download button does nothing.

Check first (everything in the folder `~/.local/share/tempbase-shim/`):
- `start.log`: the last lines say "patch-dl rc=2: pattern found N times in DL.exe ...".
- `~/.wine/drive_c/tempbase 2/DL.exe` (the new, unpatched version) and its version
  (`strings -e l DL.exe | grep -i "3\.[0-9]\.[0-9]"`).
- `install-tempbase-wine.sh --check` for the overall state.

## The cause (do not investigate again)

Already established, please do not re-investigate:
- `hid.OpenDevice()` in DL.exe opens the device with
  `Kernel32.CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0x40000000 /*FILE_FLAG_OVERLAPPED*/, 0)`
  and wraps the handle in `new FileStream(handle, FileAccess.ReadWrite, 4096, true)`.
- Wine Mono reads from it synchronously. If the response has not arrived yet, this results in
  `IOException: Win32 IO returned 997` (ERROR_IO_PENDING) in `ReadCompleted`. tempbase silently catches it
  and sets `hid.deviceOpened = false`. After that, only 4 of the 31 parameter packets of the connection
  setup (`UsbCommand.GetParameter`, 80 ms pause in between) are sent. `CUSB.connect` fails, the flag
  `deviceConnected` stays false, and every click shows the message "未连接设备" ("no device connected").
- The fix consists of two parts, both are required:
  1. `DL.exe` patch: replace the constant 0x40000000 (FILE_FLAG_OVERLAPPED) in the CreateFile call with 0
     (IL `20 00 00 00 40` -> `16 00 00 00 00`, i.e. `ldc.i4.0` + 4x `nop`).
  2. LD_PRELOAD shim `hidraw-delay.so` (source `hidraw-delay.c`): keeps 300 ms spacing between
     write() calls on `/dev/hidraw*`, because the TempMate logger (USB 04d8:0015) does not answer requests
     that follow each other more closely (block 0x60 takes about 250 ms). The shim does not depend on the
     tempbase version and normally does not need to be touched.
- Not the cause (already ruled out): Wine version 11.17/11.18, Mono 10.4.1 vs. 11.3.0, USB port,
  cable, CPU speed, udev permissions, hidraw/kernel. The logger and Wine's hid layer are fine.

The byte pattern in `patch-dl.py` (constants `PAT` / `PAT_DONE`):
```
20 00 00 00 c0   ldc.i4 0xC0000000        (GENERIC_READ|WRITE)
19               ldc.i4.3                 (share mode)
7e ?? ?? ?? ??   ldsfld IntPtr.Zero
19               ldc.i4.3                 (OPEN_EXISTING)
20 00 00 00 40   ldc.i4 0x40000000        (FILE_FLAG_OVERLAPPED)  -> should become 16 00 00 00 00
16               ldc.i4.0
28               call CreateFile
```

## Procedure for a new tempbase version

1. **Obtain the new source code.** There is no .NET decompiler on Linux. On a Windows machine, the user
   has to open `DL.exe` (the current, unpatched version: `DL.exe` or `DL.exe.orig`, depending on the
   state) in **dnSpy** and export it via "File -> Export to Project..." to e.g. `decomp-new/`
   (zip the folder and hand it over). The classes are under `tempbase2/Devices/Usb/`
   (`hid.cs`, `UsbCommand.cs`, `DataFactory.cs`) and `tempbase2/Monitor/CUSB.cs`.
   An export of version 3.1.2 may still be available for comparison in `decomp/` of the repository
   checkout (git-ignored, if present).
   Vendor code: do not pass it on, do not copy it into public reports or commit it.
2. **Find the spot again:** `grep -n "CreateFile\|1073741824\|FILE_FLAG_OVERLAPPED" hid.cs`. You are looking
   for the `CreateFile` call for `ReadHandle` in `OpenDevice` with the flag 1073741824.
   - If the call is **unchanged** but the byte pattern does not match (different compiler, different register):
     search the new `DL.exe` with Python for `20 00 00 00 40` near a `call` (print the context around the
     match) and adjust `PAT`/`PAT_DONE` in `patch-dl.py` accordingly. Always enforce exactly **one**
     match (otherwise the script deliberately refuses to patch).
   - If the vendor has **rebuilt** the HID layer (different class, HidSharp, async/await, Overlapped with
     its own structure): understand the new read path (`BeginRead`/`ReadCompleted`/`Write` in `hid.cs`) and
     check whether the error still occurs there. If necessary, choose a different patch point.
   - If the vendor has **fixed** the bug (no more OVERLAPPED): then no patch is needed. Still check
     with step 4 whether the shim alone is sufficient.
3. **Test the patch on a copy** (never on the real prefix first): apply `patch-dl.py` to a copy of `DL.exe`,
   compare the result against the original with `cmp -l` (only the 5 bytes may differ).
   Better: create a copy of the prefix (`cp -a ~/.wine ~/.wine-test`) and test there, everything via
   `WINEPREFIX=~/.wine-test`. Ask the user before making changes to the real `~/.wine`.
4. **Functional test** (logger must be plugged in, no tempbase open in the same session):
   ```
   WINEPREFIX=<prefix> WINEDEBUG=+hid,+timestamp TEMPBASE_HID_ALL=1 \
     LD_PRELOAD=~/.local/share/tempbase-shim/hidraw-delay.so \
     /opt/wine-devel/bin/wine "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\tempbase 2\tempbase 2.lnk" \
     > test.log 2>&1
   ```
   Stop after about 60 s (`wineserver -k`) and evaluate: per enumeration cycle, count the lines
   `hid_internal_dispatch write output report` (writes) and `deliver_next_report ... input report`
   (responses); a cycle starts at each `HidD_GetHidGuid` group.
   - **Success:** the first cycles have 31 writes and 31 reads, followed by cycles with 1 write/1 read each
     (monitoring mode). In the tempbase window, the status bar shows a connected device, "Download"
     shows a progress bar (the user has to look at this and confirm).
   - **Failure:** persistent cycles with only 4 writes = the same error as before (patch has no effect).
   Detailed diagnosis: compile the class `hid.cs` with Wine Mono's `mcs.exe` (`~/.wine/drive_c/windows/mono/mono-2.0/lib/mono/4.5/mcs.exe`,
   invoked with `wine`, option `-platform:x86`) together with a small test program that prints the
   exceptions (`catch (Exception __e) { Console.WriteLine(__e); }`). This is what made the
   IOException 997 error visible. Important: build as **x86**, otherwise SetupDi finds no devices.
5. **Update the tools, in both places:**
   - `~/.local/share/tempbase-shim/patch-dl.py` (used by the launcher)
   - the embedded copy in `install-tempbase-wine.sh` (section `cat > "$SHIM_DIR/patch-dl.py"`), so that
     new installations get the new pattern.
   Then run `install-tempbase-wine.sh --check` and test a real start via the Start Menu.
   If the shim needs to be changed: rebuild `hidraw-delay.c`
   (`gcc -O2 -shared -fPIC -o hidraw-delay.so hidraw-delay.c -ldl -lpthread`) and update the script as well.

## Special case: "Device disconnected" after an update, WITHOUT any error message, although `--check` shows the patch as active

Found and fixed on 2026-09-22 - please do not investigate again, just carry out:

**Cause:** During its self-update, tempbase downloads a FULL, non-silent Inno Setup installer and
runs it without silent parameters (`Process.Start(setupFileSavePath)` in `ShowNewVersion.cs`). On every run,
this setup creates a shortcut on the Windows "Desktop" (`C:\users\Public\Desktop\tempbase 2.lnk`).
Wine then creates its OWN, second `.desktop` file directly on the real desktop (`xdg-user-dir DESKTOP`,
e.g. `~/Desktop`, localized on some systems such as `~/Schreibtisch` - **independent of `XDG_DATA_HOME`**,
a sandbox override has NO effect here), with a plain `wine "...lnk"` call without our launcher.
Double-clicking this (new) desktop icon therefore bypasses patch and shim WITHOUT any message (the launcher
is never called) - just "Device disconnected" again.

**Already fixed in `install-tempbase-wine.sh`:** since then it also looks for tempbase `.desktop` files in the
real desktop directory and redirects both (Start Menu + desktop) to the launcher. Since then it also runs
WITHOUT an installer file as a pure repair run (`./install-tempbase-wine.sh --yes`, optionally `--no-apt`) when
tempbase is already installed. `--check` reports a broken desktop icon as
`[MISSING] Desktop icon without launcher`.

**Additionally hardened (also 2026-09-22):** After the fix, both `.desktop` files (Start Menu + desktop) are
write-protected with `chmod 555` (executable, but writable by nobody). Tested empirically with the real update
package downloaded directly from the vendor's server: Wine/winemenubuilder overwrites an existing
`.desktop` file via open+truncate (not via unlink+rename) and therefore respects missing write permissions - a
repeated update run left the write-protected file (inode, permissions, content) unchanged, with no error message
in the setup log. Uninstalling (unlink, only needs directory permissions) remains possible regardless.
`install-tempbase-wine.sh` briefly lifts the write protection itself during its own repair (`chmod u+w` before
writing) and restores it afterwards. This makes re-running the script after every update merely an additional
safety net, no longer a necessary step.

**Addendum from the same day - TWO of our own mistakes in the first attempt, please take both into account:**
1. At first, `chmod 444` (no X bit) was used. Result for the user: the desktop link asked
   "trusted?" (could still be started by answering yes), the Start Menu link did nothing at all - GNOME/Cinnamon/
   Nemo do not treat a `.desktop` file without the execute bit as launchable. Correction: `chmod 555` instead of
   `444` everywhere (in the fix itself AND in the newly created replacement menu entry, in case Wine did not create one).
   Important: the X bit of a `.desktop` file has NOTHING to do with whether the `Exec=` target is executable; it is
   purely a trust/launchability marker of the desktop environment.
2. The Start Menu entry `.../applications/wine/Programs/tempbase 2/tempbase 2.desktop` contained a `Path=`
   line (working directory at launch) that happened to still point to a long-deleted sandbox test folder
   (a leftover from Wine filling in this line at creation time with the WINEPREFIX of the test context
   that was running at the time). A `Path=` directory that does not exist (anymore) makes the launch fail
   silently - no dialog, no error message, the icon simply does nothing. Since then, `fix_desktop_file()` in
   `install-tempbase-wine.sh` ALWAYS sets `Path=` explicitly to `$TB_DIR` (the real tempbase folder in the
   current `$WINEPREFIX`), regardless of what was there before.
   **Lesson for your own tests:** sandbox test runs (with their own `WINEPREFIX`/`XDG_DATA_HOME`) can still write
   into the REAL `~/.local/share/applications/**` files if Wine's winemenubuilder happens to record the
   currently active `WINEPREFIX` path in them (analogous to the desktop case above). After sandbox tests, always
   check `grep -r "Path=\|scratchpad\|/tmp/" ~/.local/share/applications "$(xdg-user-dir DESKTOP)" 2>/dev/null` to find
   contamination of the real files before considering the case closed.

**Also verified with the real update package:** the Windows Start Menu entry itself is NOT rewritten by a
tempbase self-update (timestamps before/after a real version jump 3.1.2 -> 3.1.4 identical down to the
nanosecond) - only the newly created desktop icon is affected. The update URL/XML is hard-coded in
`Tasks/AutoUpgrade/CCheckNewVersionTask.cs`
(`http://www.tempmate.com/downloads/tempbase2/Server.xml`, containing `ReleaseUrl`) and can therefore be
downloaded directly for tests without having to click through the update dialog in the running application.

**If it happens again anyway:**
1. `install-tempbase-wine.sh --check`; if it reports "Desktop icon without launcher", simply run
   `install-tempbase-wine.sh --yes` (without installer file) again.
2. If `xdg-user-dir DESKTOP` does not return the directory actually in use: search manually with
   `grep -rl "tempbase" ~/Desktop ~/.local/share/applications 2>/dev/null | xargs grep -L "tempbase-start.sh"`
   (add the localized desktop folder, e.g. `~/Schreibtisch`, if there is one).
   CAUTION (fell into this trap ourselves): if the desktop folder is a symlink (e.g. to a cloud sync folder,
   `readlink "$(xdg-user-dir DESKTOP)"` shows it), `find <symlink> ...` WITHOUT `-L` finds NOTHING in it -
   resolve it to the real path with `readlink -f` first (`install-tempbase-wine.sh` already does this for
   `DESKTOP_DIR`).
3. If tempbase creates further shortcut locations in the future (quick launch, pinned): same pattern - find the file,
   `chmod u+w`, redirect `Exec=` (and if needed `Path=`) to the launcher/`$TB_DIR` via `sed`, `chmod 555`.

## Notes

- The session cannot run sudo commands itself (password). The user types them with `! <command>`.
- Ask the user before making changes to the real prefix, to `.desktop` files, or to the installed system packages.
- After every test, terminate tempbase/wineserver processes (`WINEPREFIX=... wineserver -k`) and delete test copies
  of the prefix (about 2 GB each) again.
- If a Wine update or a new Mono breaks something else: first check whether
  `IOException 997` still occurs (test program above). A draft report on this for the Wine Mono project
  (`wine-mono-bugreport-filestream-overlapped.md` with `Repro.cs`, as of 2026-09-21) exists but has not been
  submitted yet and is not part of this repository.
  If the bug is fixed in Wine Mono, the DL.exe patch is no longer needed.
MDEOF

# Redirects a .desktop file to the launcher and then makes it read-only
# (chmod 555). Wine/winemenubuilder overwrites an existing .desktop file via
# open+truncate (not via unlink+rename) - this respects normal file permissions,
# deleting it when uninstalling (unlink, only needs directory permissions) still works.
# This way our redirection survives even if tempbase/Wine later tries to create
# the same file again (see "Special case" in REPAIR.md).
fix_desktop_file() {
    local df="$1" backup="$2"
    chmod u+w "$df" 2>/dev/null || true
    cp -n -p "$df" "$backup" 2>/dev/null || true
    sed -i -E "s#^(Exec(\[[a-z_A-Z@]+\])?=).*#\1\"$SHIM_DIR/tempbase-start.sh\"#" "$df"
    # Also pin "Path=" (working directory at launch) to the real tempbase folder instead
    # of relying on whatever Wine put there - a wrong/no longer existing path otherwise
    # makes the launch fail silently (no dialog, no error message, the Start Menu icon
    # simply does nothing).
    if grep -q '^Path=' "$df"; then
        sed -i -E "s#^Path=.*#Path=$TB_DIR#" "$df"
    else
        printf 'Path=%s\n' "$TB_DIR" >> "$df"
    fi
    # chmod 555 rather than 444: the execute bit is needed for GNOME/Cinnamon/Nemo to
    # treat the file as a launchable/trusted .desktop file at all. The W bit stays unset
    # for everyone - that (not the X bit) is what stops Wine from silently overwriting
    # the file during a tempbase update.
    chmod 555 "$df"
}

mkdir -p "$APPS_DIR"
DESKTOP_FILES=$(find "$APPS_DIR" -iname "*tempbase*.desktop" 2>/dev/null | grep -vi "${UNINSTALL_FILTER[@]}" || true)
if [ -n "$DESKTOP_FILES" ]; then
    while IFS= read -r DF; do
        fix_desktop_file "$DF" "$SHIM_DIR/$(basename "$DF").orig"
        echo "    Menu entry redirected and made read-only: $DF"
    done <<< "$DESKTOP_FILES"
else
    ICON=$(find "$DATA_HOME/icons" -iname "*tempbase*" -o -iname "*DL*.png" 2>/dev/null | head -1 || true)
    cat > "$APPS_DIR/tempbase-2.desktop" <<DEOF
[Desktop Entry]
Type=Application
Name=tempbase 2
Comment=Read out TempMate loggers (Wine)
Exec="$SHIM_DIR/tempbase-start.sh"
Icon=${ICON:-wine}
Categories=Utility;
StartupNotify=true
DEOF
    chmod 555 "$APPS_DIR/tempbase-2.desktop"
    echo "    Wine did not create a menu entry; created: $APPS_DIR/tempbase-2.desktop"
fi
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true

# Desktop icon: Wine creates it directly in $DESKTOP_DIR, independent of XDG_DATA_HOME,
# as soon as any Windows shortcut is located under "...\Desktop" (e.g. through the full,
# non-silent setup of the tempbase self-update). If present, redirect it to the launcher
# as well - otherwise double-clicking it starts unpatched tempbase.
# The write protection (see above) prevents Wine from overwriting this icon again on the
# next update (tested: Wine overwrites via open+truncate, not via unlink+rename, and
# therefore respects missing write permissions).
if [ -d "$DESKTOP_DIR" ]; then
    DESKTOP_ICON_FILES=$(find "$DESKTOP_DIR" -maxdepth 1 -iname "*tempbase*.desktop" 2>/dev/null | grep -vi "${UNINSTALL_FILTER[@]}" || true)
    if [ -n "$DESKTOP_ICON_FILES" ]; then
        while IFS= read -r DF; do
            fix_desktop_file "$DF" "$SHIM_DIR/desktop-$(basename "$DF").orig"
            echo "    Desktop icon redirected and made read-only: $DF"
        done <<< "$DESKTOP_ICON_FILES"
    fi
fi

# ------------------------------------------------------- 6. Check
info "6/6: Final check"
FAILED=0
check_install || FAILED=1

echo ""
echo "==> Done."
if [ "${NEED_RELOGIN:-0}" = 1 ]; then
    echo "    IMPORTANT: For the plugdev group to take effect, log out and back in once (or reboot),"
    echo "    otherwise tempbase has no access to the USB logger."
fi
echo "    Plug in the logger (if it is already plugged in, unplug and replug it once),"
echo "    then start tempbase 2 from the Start Menu. Connecting takes about 10 s at startup."
echo "    The launcher checks the USB patch on every start and re-applies it after a tempbase update."
echo "    Start Menu and desktop icons are now read-only, so that a tempbase self-update"
echo "    cannot replace them with an unpatched launch command again."
echo "    Should 'Device disconnected' without an error message ever show up again, re-running"
echo "    this script without an installer file helps:  $0"
echo "    Check later:  $0 --check"
exit "$FAILED"
