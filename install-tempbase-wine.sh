#!/usr/bin/env bash
#
# install-tempbase-wine.sh - Linux-Installationsskript fuer tempbase 2
#
# Installiert aus der Windows-Setup-Datei von tempbase 2 ein lauffaehiges
# Programm unter Wine, inklusive USB-Fix fuer den TempMate-Logger.
# Getestet fuer Linux Mint 22 / Ubuntu 24.04 (apt, WineHQ-Repository).
#
# Aufruf:
#   ./install-tempbase-wine.sh "/pfad/zu/tempbase 2 V3.1.2.exe"   # Erstinstallation
#   ./install-tempbase-wine.sh                    # Reparatur (Datei nicht noetig,
#                                                  # wenn tempbase 2 schon installiert ist)
#   ./install-tempbase-wine.sh --pruefen          # nur den Zustand pruefen
#
# Optionen:
#   --ja           Rueckfragen automatisch mit "ja" beantworten
#   --ohne-apt     Keine Systempakete/udev/Gruppen aendern (nur Prefix und Programm)
#   --pruefen      Nichts installieren, nur die Installation ueberpruefen
# Umgebungsvariablen:
#   WINEPREFIX     Wine-Prefix (Standard: ~/.wine)
#   XDG_DATA_HOME  Ort fuer Menue-Eintraege und Hilfsdateien (Standard: ~/.local/share)
#
# Was das Skript macht:
#   1. Systempakete: i386-Architektur, winbind, gcc u.a.; WineHQ-Repository;
#      winehq-devel (der stable-Zweig 11.0 hat einen USB-Fehler, EIO beim Lesen)
#   2. udev-Regel und Gruppe "plugdev", damit der normale Benutzer auf den
#      USB-Logger (04d8:0015) zugreifen darf
#   3. frischer 64-Bit-Prefix (ein vorhandener wird beiseitegesichert), wine-mono
#      wird vorher geladen und still installiert (kein Mono-Dialog)
#   4. stille Installation von tempbase 2
#   5. USB-Fix (Hintergrund siehe unten): DL.exe patchen, HID-Shim bauen,
#      Programmstarter mit automatischer Patch-Pruefung bei jedem Start,
#      Startmenue- UND Schreibtisch-Eintraege darauf umstellen
#   6. Abschlusspruefung
#
# Ohne Installationsdatei aufgerufen, wenn tempbase 2 schon installiert ist, wird nur
# Schritt 5+6 wiederholt - das ist der empfohlene Weg, um den Fix nach einer
# tempbase-Selbstaktualisierung erneut anzuwenden (siehe Punkt d unten).
#
# Hintergrund des USB-Fixes ("Device disconnected"):
#   a) DL.exe oeffnet den Logger mit FILE_FLAG_OVERLAPPED, liest aber ueber ein
#      synchron arbeitendes .NET-FileStream (Wine Mono). Trifft ein Lesevorgang
#      auf eine noch nicht gelieferte Antwort, kommt ERROR_IO_PENDING (997).
#      tempbase faengt die Ausnahme still ab und bricht den Verbindungsaufbau
#      nach 4 von 31 Paketen ab. -> DL.exe wird an einer Stelle gepatcht
#      (Konstante 0x40000000 -> 0). Das Original bleibt als DL.exe.orig erhalten.
#   b) Der Logger beantwortet Anfragen nicht, die dichter als ca. 300 ms
#      aufeinander folgen (tempbase sendet alle 80 ms). -> LD_PRELOAD-Shim.
#   c) tempbase aktualisiert sich selbst und ersetzt dabei DL.exe. Der Starter
#      (tempbase-start.sh) prueft deshalb bei jedem Start, ob der Patch drin
#      ist, und patcht bei Bedarf neu. Passt das Byte-Muster nicht mehr, aendert
#      er nichts, zeigt eine Meldung und startet tempbase trotzdem.
#      Protokoll: <XDG_DATA_HOME>/tempbase-shim/start.log
#   d) Die Selbstaktualisierung laedt dafuer ein VOLLES, nicht-stilles Setup
#      herunter und startet es ohne Silent-Parameter (im Gegensatz zur stillen
#      Erstinstallation durch dieses Skript). Dieses Setup legt dabei jedes Mal
#      neu eine Verknuepfung auf dem Windows-"Desktop" an. Wine erzeugt dafuer
#      ein EIGENES, zweites .desktop direkt auf dem echten Schreibtisch
#      (unabhaengig von XDG_DATA_HOME) mit einem PLAIN "wine ..."-Aufruf, ohne
#      unseren Starter. Ein Doppelklick auf dieses (neue) Schreibtisch-Symbol
#      umgeht damit sowohl den USB-Patch als auch den HID-Shim, OHNE dass
#      irgendeine Fehlermeldung erscheint (der Starter wird ja gar nicht
#      aufgerufen) - nur "Device disconnected" wie zuvor. Der Windows-
#      Startmenue-Eintrag selbst ist davon nachweislich NICHT betroffen (getestet
#      mit einem echten Versions-Update): Wine erkennt ihn als bereits vorhanden
#      und schreibt ihn nicht neu.
#      -> Dieses Skript biegt ein vorhandenes Schreibtisch-Symbol ebenfalls auf
#      den Starter um (Schritt 5) und macht danach BEIDE Verknuepfungen
#      schreibgeschuetzt (chmod 444): Wine ueberschreibt eine bestehende
#      .desktop-Datei nachweislich per open+truncate, nicht per unlink+rename,
#      und haelt sich daher an fehlende Schreibrechte (ein spaeteres Loeschen
#      beim Deinstallieren bleibt moeglich, da unlink nur Verzeichnisrechte
#      braucht). Ein erneuter Lauf dieses Skripts nach einem Update ist damit nur
#      noch ein zusaetzliches Sicherheitsnetz, keine notwendige Voraussetzung.

set -euo pipefail

# ---------------------------------------------------------------- Einstellungen
WINEPREFIX="${WINEPREFIX:-$HOME/.wine}"
export WINEPREFIX
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS_DIR="$DATA_HOME/applications"
SHIM_DIR="$DATA_HOME/tempbase-shim"
# Wine legt fuer JEDE Windows-Verknuepfung, die unter "...\Desktop" liegt, zusaetzlich
# ein eigenes .desktop auf dem echten Schreibtisch an (ueber xdg-user-dir, UNABHAENGIG
# von XDG_DATA_HOME). tempbase legt bei seiner Selbstaktualisierung (volles, nicht
# stilles Setup) jedes Mal so eine Verknuepfung neu an - dieser zweite Ort muss beim
# Patchen der Programmstarter mit beruecksichtigt werden, sonst zeigt ein Doppelklick
# auf das Schreibtisch-Symbol nach einem Update wieder auf ungepatchtes tempbase.
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
[ -n "$DESKTOP_DIR" ] || DESKTOP_DIR="$HOME/Desktop"
# Manche Setups (z.B. Schreibtisch als Symlink auf einen Cloud-Sync-Ordner) haben hier
# einen symbolischen Link. "find" folgt einem Symlink als Startpfad standardmaessig NICHT
# und faende dann nichts darin - deshalb hier einmal auf den echten Pfad aufloesen.
DESKTOP_DIR="$(readlink -f "$DESKTOP_DIR" 2>/dev/null || echo "$DESKTOP_DIR")"
WINE=/opt/wine-devel/bin/wine
WINESERVER=/opt/wine-devel/bin/wineserver
TB_DIR="$WINEPREFIX/drive_c/tempbase 2"
UDEV_RULE=/etc/udev/rules.d/99-tempmate-hidraw.rules
TEMPMATE_VID="04d8"
TEMPMATE_PID="0015"

JA=0; OHNE_APT=0; NUR_PRUEFEN=0; INSTALLER=""

info() { echo "==> $*"; }
warn() { echo "    Warnung: $*" >&2; }
die()  { echo "Fehler: $*" >&2; exit 1; }

frage() {   # frage "Text"  -> 0 bei ja
    [ "$JA" = 1 ] && return 0
    local a; read -r -p "$1 [j/N] " a
    case "$a" in j|J|ja|Ja|JA|y|Y) return 0;; *) return 1;; esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ja) JA=1;;
        --ohne-apt) OHNE_APT=1;;
        --pruefen) NUR_PRUEFEN=1;;
        -h|--help) sed -n '2,50p' "$0"; exit 0;;
        -*) die "Unbekannte Option: $1 (siehe --help)";;
        *) [ -z "$INSTALLER" ] || die "Nur eine Installationsdatei angeben."; INSTALLER="$1";;
    esac
    shift
done

# ------------------------------------------------------- Abschlusspruefung
pruefen() {
    local fail=0
    ok()  { printf '  [OK]     %s\n' "$*"; }
    bad() { printf '  [FEHLT]  %s\n' "$*"; fail=1; }
    hin() { printf '  [HINWEIS] %s\n' "$*"; }

    info "Pruefung der Installation"
    if [ -x "$WINE" ]; then ok "wine-devel: $("$WINE" --version 2>/dev/null)"; else bad "wine-devel ($WINE) fehlt"; fi
    if [ -f "$WINEPREFIX/drive_c/windows/mono/mono-2.0/bin/libmono-2.0-x86.dll" ]; then
        ok "wine-mono im Prefix"; else bad "wine-mono fehlt im Prefix $WINEPREFIX"; fi
    if [ -f "$TB_DIR/DL.exe" ]; then
        ok "tempbase 2: $TB_DIR/DL.exe"
        if [ -f "$SHIM_DIR/patch-dl.py" ]; then
            local tmp out rc; tmp=$(mktemp); cp "$TB_DIR/DL.exe" "$tmp"
            out=$(python3 "$SHIM_DIR/patch-dl.py" "$tmp" 2>&1) && rc=0 || rc=$?
            rm -f "$tmp" "$tmp.orig"
            if [ "$rc" = 0 ] && [ "$out" = "bereits gepatcht" ]; then ok "USB-Patch in DL.exe ist aktiv"
            elif [ "$rc" = 0 ]; then hin "DL.exe ist noch nicht gepatcht; der Starter holt das beim naechsten Start nach"
            else bad "USB-Patch nicht anwendbar: $out"; fi
        else bad "patch-dl.py fehlt in $SHIM_DIR"; fi
    else bad "tempbase 2 nicht gefunden ($TB_DIR/DL.exe)"; fi
    if [ -s "$SHIM_DIR/hidraw-delay.so" ]; then ok "HID-Shim gebaut"; else bad "HID-Shim fehlt"; fi
    if [ -x "$SHIM_DIR/tempbase-start.sh" ]; then ok "Programmstarter vorhanden"; else bad "Programmstarter fehlt"; fi
    local n=0 z
    while IFS= read -r z; do
        [ -n "$z" ] || continue
        if grep -q "tempbase-start.sh" "$z"; then n=$((n+1)); else bad "Menue-Eintrag ohne Starter: $z"; fi
    done < <(find "$APPS_DIR" -iname "*tempbase*.desktop" 2>/dev/null | grep -vi -e entfernen -e uninstall -e remove -e deinstall || true)
    if [ "$n" -gt 0 ]; then ok "Startmenue-Eintraege ($n) nutzen den Starter"; else bad "kein Startmenue-Eintrag mit Starter"; fi
    local d=0
    while IFS= read -r z; do
        [ -n "$z" ] || continue
        if grep -q "tempbase-start.sh" "$z"; then d=$((d+1)); else bad "Schreibtisch-Symbol ohne Starter (zeigt auf ungepatchtes tempbase): $z"; fi
    done < <(find "$DESKTOP_DIR" -maxdepth 1 -iname "*tempbase*.desktop" 2>/dev/null | grep -vi -e entfernen -e uninstall -e remove -e deinstall || true)
    [ "$d" -gt 0 ] && ok "Schreibtisch-Symbol ($d) nutzt den Starter"
    if [ -f "$UDEV_RULE" ]; then ok "udev-Regel vorhanden"; else bad "udev-Regel fehlt ($UDEV_RULE)"; fi
    if id -nG "${USER:-$(id -un)}" | grep -qw plugdev; then ok "Benutzer ist in Gruppe plugdev"
    else bad "Benutzer nicht in Gruppe plugdev (nach Aenderung: neu anmelden)"; fi
    local h found=0
    for h in /sys/class/hidraw/hidraw*; do
        [ -e "$h" ] || continue
        if readlink -f "$h/device" | grep -qi "0003:0*${TEMPMATE_VID}:0*${TEMPMATE_PID}"; then
            found=1; local node="/dev/$(basename "$h")"
            if [ -r "$node" ] && [ -w "$node" ]; then ok "Logger eingesteckt, Zugriff auf $node moeglich"
            else bad "Logger gefunden ($node), aber kein Zugriff (Gruppe/udev/neu einstecken)"; fi
        fi
    done
    [ "$found" = 1 ] || hin "Kein TempMate-Logger eingesteckt (nicht pruefbar)"
    echo
    if [ "$fail" = 0 ]; then echo "Ergebnis: alles in Ordnung."; else echo "Ergebnis: es gibt offene Punkte (siehe oben)."; fi
    return "$fail"
}

if [ "$NUR_PRUEFEN" = 1 ]; then pruefen; exit $?; fi

# ------------------------------------------------------------------- Vorpruefungen
[ "$(id -u)" != 0 ] || die "Bitte NICHT als root starten (das Skript fragt bei Bedarf per sudo)."
if [ -z "$INSTALLER" ] && [ ! -f "$TB_DIR/DL.exe" ]; then
    echo "Aufruf: $0 [--ja] [--ohne-apt] \"/pfad/zur/tempbase-installer.exe\"" >&2
    echo "(Die Installationsdatei ist nur beim allerersten Mal noetig; tempbase 2 ist unter" >&2
    echo " $WINEPREFIX noch nicht installiert.)" >&2
    exit 1
fi
if [ -n "$INSTALLER" ]; then
    [ -f "$INSTALLER" ] || die "Installationsdatei nicht gefunden: $INSTALLER"
    [ "$(head -c 2 "$INSTALLER")" = "MZ" ] || die "Das ist keine Windows-Programmdatei (.exe): $INSTALLER"
    INSTALLER="$(readlink -f "$INSTALLER")"
elif [ -f "$TB_DIR/DL.exe" ]; then
    info "Keine Installationsdatei angegeben, tempbase 2 ist bereits installiert - repariere nur"
    info "(USB-Patch, HID-Shim, Programmstarter, Menue-/Schreibtisch-Eintraege)."
fi
if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    warn "Keine grafische Sitzung erkannt (DISPLAY leer). Die Installation braucht eine."
fi

# ------------------------------------------------- 1. Systempakete und WineHQ
if [ "$OHNE_APT" = 1 ]; then
    info "1/6: Systempakete uebersprungen (--ohne-apt)"
    [ -x "$WINE" ] || die "$WINE fehlt. Ohne --ohne-apt erneut starten."
else
    command -v apt >/dev/null 2>&1 || die "Nur fuer Debian/Ubuntu/Linux Mint (apt) gedacht."
    . /etc/os-release
    CODENAME="${UBUNTU_CODENAME:-}"
    [ -n "$CODENAME" ] || { [ "${ID:-}" = ubuntu ] && CODENAME="${VERSION_CODENAME:-}"; }
    [ -n "$CODENAME" ] || die "Ubuntu-Codename nicht ermittelbar (/etc/os-release). Siehe https://wiki.winehq.org/Ubuntu"

    info "1/6: Systempakete (i386, winbind, Werkzeuge) und WineHQ-Repository (Codename: $CODENAME)"
    sudo dpkg --add-architecture i386
    sudo apt update
    sudo apt install -y winbind wget ca-certificates gnupg python3 build-essential
    sudo mkdir -pm755 /etc/apt/keyrings
    sudo wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
    sudo wget -qNP /etc/apt/sources.list.d/ \
        "https://dl.winehq.org/wine-builds/ubuntu/dists/${CODENAME}/winehq-${CODENAME}.sources" \
        || die "Kein WineHQ-Repository fuer '$CODENAME' gefunden."
    sudo apt update
    if [ -x "$WINE" ]; then
        echo "    wine-devel ist bereits installiert."
    else
        sudo apt install -y --install-recommends winehq-devel
    fi
    sudo apt install -y libegl1:i386 libegl-mesa0:i386 || warn "32-Bit-EGL-Bibliotheken nicht installierbar (meist unkritisch)."
    [ -x "$WINE" ] || die "$WINE fehlt nach der Installation von winehq-devel."

    info "2/6: USB-Zugriff fuer den TempMate-Logger (udev-Regel, Gruppe plugdev)"
    RULE_LINE="SUBSYSTEM==\"hidraw\", ATTRS{idVendor}==\"${TEMPMATE_VID}\", ATTRS{idProduct}==\"${TEMPMATE_PID}\", MODE=\"0660\", GROUP=\"plugdev\", TAG+=\"uaccess\""
    if [ -f "$UDEV_RULE" ] && grep -qF "$RULE_LINE" "$UDEV_RULE"; then
        echo "    Regel existiert bereits."
    else
        echo "$RULE_LINE" | sudo tee "$UDEV_RULE" >/dev/null
        sudo udevadm control --reload-rules
        sudo udevadm trigger --subsystem-match=hidraw
        echo "    Regel installiert."
    fi
    if id -nG "$USER" | grep -qw plugdev; then
        echo "    $USER ist bereits in der Gruppe plugdev."
    else
        sudo usermod -aG plugdev "$USER"
        NEUANMELDEN=1
        echo "    $USER zur Gruppe plugdev hinzugefuegt (Neuanmeldung noetig, siehe Ende)."
    fi
fi
command -v python3 >/dev/null 2>&1 || die "python3 fehlt."

# ------------------------------------------------------ 3. Prefix und Mono
if [ -f "$TB_DIR/DL.exe" ]; then
    info "3/6 + 4/6: tempbase 2 ist im Prefix $WINEPREFIX bereits installiert; ueberspringe Prefix und Setup"
else
    info "3/6: Wine-Prefix anlegen: $WINEPREFIX"
    "$WINESERVER" -k 2>/dev/null || true
    if [ -e "$WINEPREFIX" ]; then
        BACKUP="${WINEPREFIX}-backup-$(date +%Y%m%d-%H%M%S)"
        echo "    Ein Prefix existiert bereits (ohne tempbase 2)."
        frage "    Nach $BACKUP verschieben und einen frischen Prefix anlegen?" || die "Abgebrochen. Mit anderem WINEPREFIX erneut versuchen."
        mv "$WINEPREFIX" "$BACKUP"
        echo "    Gesichert nach: $BACKUP"
    fi

    # Wine-Mono: Version steht in appwiz.cpl; vorab laden, damit Wine keinen Dialog zeigt
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
            echo "    Lade $MONO_MSI ..."
            wget -q -O "$MONO_CACHE/$MONO_MSI.part" "https://dl.winehq.org/wine/wine-mono/$MONO_VER/$MONO_MSI" \
                && mv "$MONO_CACHE/$MONO_MSI.part" "$MONO_CACHE/$MONO_MSI" \
                || { rm -f "$MONO_CACHE/$MONO_MSI.part"; warn "Mono-Download fehlgeschlagen."; MONO_MSI=""; }
        fi
    else
        warn "Mono-Version nicht ermittelbar."
    fi

    # Mono/Gecko-Dialoge unterdruecken, Mono danach gezielt still installieren
    env WINEARCH=win64 WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" "$WINE" wineboot --init 2>&1 | grep -v -e MESA -e ELFCLASS || true
    "$WINESERVER" -w
    if [ -n "$MONO_MSI" ] && [ -s "$MONO_CACHE/$MONO_MSI" ]; then
        echo "    Installiere Wine Mono $MONO_VER ..."
        env WINEDEBUG=-all "$WINE" msiexec /i "$(env WINEDEBUG=-all "$WINE" winepath -w "$MONO_CACHE/$MONO_MSI" 2>/dev/null | tr -d '\r')" /qn 2>&1 | grep -v -e MESA -e ELFCLASS || true
        "$WINESERVER" -w
    fi
    [ -f "$WINEPREFIX/drive_c/windows/mono/mono-2.0/bin/libmono-2.0-x86.dll" ] \
        || warn "Wine Mono fehlt im Prefix. Beim ersten Start ggf. den Mono-Dialog mit 'Installieren' bestaetigen."

    info "4/6: tempbase 2 installieren (still)"
    env WINEDEBUG=-all "$WINE" "$INSTALLER" /SILENT /SUPPRESSMSGBOXES /NORESTART 2>&1 | grep -v -e MESA -e ELFCLASS || true
    "$WINESERVER" -w
    if [ ! -f "$TB_DIR/DL.exe" ]; then
        FOUND=$(find "$WINEPREFIX/drive_c" -maxdepth 4 -name DL.exe 2>/dev/null | head -1 || true)
        die "DL.exe nicht unter $TB_DIR gefunden${FOUND:+ (gefunden: $FOUND; der USB-Fix erwartet 'C:\\tempbase 2')}. Installation fehlgeschlagen?"
    fi
    echo "    tempbase 2 installiert: $TB_DIR"
fi

# ---------------------------------------------------------- 5. USB-Fix
info "5/6: USB-Fix (DL.exe-Patch, HID-Shim, Starter, Menue-Eintraege)"
mkdir -p "$SHIM_DIR"

cat > "$SHIM_DIR/patch-dl.py" <<'PYEOF'
#!/usr/bin/env python3
"""Entfernt FILE_FLAG_OVERLAPPED aus tempbase 2 (DL.exe), siehe fix-tempbase-wine-usb.sh.

Exit-Codes: 0 = gepatcht oder bereits gepatcht, 2 = Muster nicht (genau einmal) gefunden,
            1 = Datei fehlt/Fehler. Bei Exit-Code != 0 wird nichts veraendert.
"""
import os, re, shutil, sys

# IL: ldc.i4 0xC0000000 / ldc.i4.3 / ldsfld IntPtr.Zero / ldc.i4.3 /
#     ldc.i4 0x40000000 (FILE_FLAG_OVERLAPPED) / ldc.i4.0 / call CreateFile
PAT = rb"\x20\x00\x00\x00\xc0\x19\x7e....\x19\x20\x00\x00\x00\x40\x16\x28"
PAT_DONE = rb"\x20\x00\x00\x00\xc0\x19\x7e....\x19\x16\x00\x00\x00\x00\x16\x28"

def main():
    if len(sys.argv) != 2:
        print("Aufruf: patch-dl.py <DL.exe>", file=sys.stderr); return 1
    p = sys.argv[1]
    try:
        d = bytearray(open(p, "rb").read())
    except OSError as e:
        print("DL.exe nicht lesbar: %s" % e, file=sys.stderr); return 1
    if re.search(PAT_DONE, bytes(d), re.S):
        print("bereits gepatcht"); return 0
    ms = list(re.finditer(PAT, bytes(d), re.S))
    if len(ms) != 1:
        print("Muster in DL.exe %d mal gefunden (erwartet: 1). Vermutlich andere "
              "tempbase-Version; nichts geaendert." % len(ms), file=sys.stderr)
        return 2
    try:
        shutil.copy2(p, p + ".orig")          # aktuelle, ungepatchte Version sichern
        o = ms[0].start() + 12
        d[o:o + 5] = b"\x16\x00\x00\x00\x00"  # ldc.i4.0 + 4x nop
        open(p, "wb").write(d)
    except OSError as e:
        print("Schreiben fehlgeschlagen: %s" % e, file=sys.stderr); return 1
    print("gepatcht (Offset 0x%x), Original: %s.orig" % (o, p))
    return 0

if __name__ == "__main__":
    sys.exit(main())
PYEOF
chmod +x "$SHIM_DIR/patch-dl.py"
python3 "$SHIM_DIR/patch-dl.py" "$TB_DIR/DL.exe" | sed 's/^/    DL.exe: /' \
    || warn "DL.exe konnte nicht gepatcht werden (andere tempbase-Version?). Siehe $SHIM_DIR/start.log nach dem ersten Start."

cat > "$SHIM_DIR/hidraw-delay.c" <<'CEOF'
/*
 * LD_PRELOAD-Shim fuer tempbase 2 unter Wine.
 * Der TempMate-Logger (USB 04d8:0015) beantwortet Anfragen nicht, wenn sie zu
 * dicht aufeinander folgen (tempbase sendet alle 80 ms). Dieser Shim haelt bei
 * write() auf /dev/hidraw* mindestens TEMPBASE_HID_DELAY_MS (Standard 300)
 * Abstand zwischen zwei Schreibzugriffen ein. Mit TEMPBASE_HID_ALL=1 gilt das
 * fuer jede Anfrage; ohne nur nach Anfragen fuer Speicherblock 0x60.
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
command -v gcc >/dev/null 2>&1 || die "gcc fehlt (build-essential installieren oder ohne --ohne-apt starten)."
gcc -O2 -shared -fPIC -o "$SHIM_DIR/hidraw-delay.so" "$SHIM_DIR/hidraw-delay.c" -ldl -lpthread
echo "    HID-Shim gebaut: $SHIM_DIR/hidraw-delay.so"

cat > "$SHIM_DIR/tempbase-start.sh" <<'SHEOF'
#!/usr/bin/env bash
# Starter fuer tempbase 2 unter Wine: prueft/patcht DL.exe, setzt den HID-Shim, startet tempbase.
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
    msg="tempbase 2: Der USB-Fix konnte nicht angewendet werden ($out). Vermutlich wurde tempbase aktualisiert. \"Device disconnected\" ist dann wahrscheinlich. Anleitung fuer eine Claude-Sitzung: $DIR/REPARATUR.md (Protokoll: $LOG)."
    if command -v notify-send >/dev/null 2>&1; then notify-send -u critical "tempbase 2" "$msg"
    elif command -v zenity >/dev/null 2>&1; then zenity --warning --text="$msg" &
    else echo "$msg" >&2; fi
fi
exec "$WINE" "C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\tempbase 2\\tempbase 2.lnk" "$@"
SHEOF
chmod +x "$SHIM_DIR/tempbase-start.sh"

cat > "$SHIM_DIR/REPARATUR.md" <<'MDEOF'
# tempbase 2 unter Wine: USB-Patch schlaegt fehl - Anleitung fuer eine Claude-Sitzung

Diese Datei ist ein Prompt/Uebergabe-Text. Sie liegt in `<XDG_DATA_HOME>/tempbase-shim/REPARATUR.md`
(Standard `~/.local/share/tempbase-shim/`). Der Benutzer gibt sie einer neuen Claude-Code-Sitzung.
Kommuniziert wird auf Deutsch.

## Ausgangslage

tempbase 2 (.NET-Programm `DL.exe`, Hersteller TempMate) wird per `install-tempbase-wine.sh`
unter Wine (wine-devel, `/opt/wine-devel`) betrieben. Der Programmstarter
`tempbase-start.sh` ruft bei jedem Start `patch-dl.py` auf. Das Patch-Werkzeug hat das
Byte-Muster in `DL.exe` nicht (genau einmal) gefunden. Vermutlich hat sich tempbase per
Selbstupdate (`setup.exe`) auf eine neue Version aktualisiert. Ohne Patch zeigt tempbase bei jedem
Klick "Device disconnected", der Download-Knopf tut nichts.

Zuerst pruefen (alles im Ordner `~/.local/share/tempbase-shim/`):
- `start.log`: letzte Zeilen, dort steht "patch-dl rc=2: Muster ... N mal gefunden".
- `~/.wine/drive_c/tempbase 2/DL.exe` (die neue, ungepatchte Version) und ihre Version
  (`strings -e l DL.exe | grep -i "3\.[0-9]\.[0-9]"`).
- `install-tempbase-wine.sh --pruefen` fuer den Gesamtzustand.

## Die Ursache (nicht neu untersuchen)

Bereits gesichert, bitte nicht erneut ermitteln:
- `hid.OpenDevice()` in DL.exe oeffnet das Geraet mit
  `Kernel32.CreateFile(pfad, 0xC0000000, 3, IntPtr.Zero, 3, 0x40000000 /*FILE_FLAG_OVERLAPPED*/, 0)`
  und packt das Handle in `new FileStream(handle, FileAccess.ReadWrite, 4096, true)`.
- Wine Mono liest darauf synchron. Ist die Antwort noch nicht da, gibt es
  `IOException: Win32 IO returned 997` (ERROR_IO_PENDING) in `ReadCompleted`. tempbase faengt sie still ab
  und setzt `hid.deviceOpened = false`. Danach werden von den 31 Parameter-Paketen des Verbindungsaufbaus
  (`UsbCommand.GetParameter`, 80 ms Pause dazwischen) nur 4 gesendet. `CUSB.connect` scheitert, der Flag
  `deviceConnected` bleibt falsch, jeder Klick zeigt die Meldung "未连接设备" ("kein Geraet verbunden").
- Der Fix besteht aus zwei Teilen, beide sind noetig:
  1. `DL.exe`-Patch: die Konstante 0x40000000 (FILE_FLAG_OVERLAPPED) beim CreateFile-Aufruf durch 0
     ersetzen (IL `20 00 00 00 40` -> `16 00 00 00 00`, also `ldc.i4.0` + 4x `nop`).
  2. LD_PRELOAD-Shim `hidraw-delay.so` (Quelltext `hidraw-delay.c`): haelt 300 ms Abstand zwischen
     write()-Aufrufen auf `/dev/hidraw*`, weil der TempMate-Logger (USB 04d8:0015) dichter aufeinander
     folgende Anfragen nicht beantwortet (Block 0x60 braucht ca. 250 ms). Der Shim ist unabhaengig von der
     tempbase-Version und muss normalerweise nicht angefasst werden.
- Nicht ursaechlich (bereits ausgeschlossen): Wine-Version 11.17/11.18, Mono 10.4.1 vs. 11.3.0, USB-Port,
  Kabel, CPU-Geschwindigkeit, udev-Rechte, hidraw/Kernel. Der Logger und Wines hid-Schicht sind in Ordnung.

Das Byte-Muster in `patch-dl.py` (Konstanten `PAT` / `PAT_DONE`):
```
20 00 00 00 c0   ldc.i4 0xC0000000        (GENERIC_READ|WRITE)
19               ldc.i4.3                 (Share-Modus)
7e ?? ?? ?? ??   ldsfld IntPtr.Zero
19               ldc.i4.3                 (OPEN_EXISTING)
20 00 00 00 40   ldc.i4 0x40000000        (FILE_FLAG_OVERLAPPED)  -> soll 16 00 00 00 00 werden
16               ldc.i4.0
28               call CreateFile
```

## Vorgehen bei einer neuen tempbase-Version

1. **Neuen Quelltext beschaffen.** Auf Linux gibt es keinen .NET-Decompiler. Der Benutzer muss auf einem
   Windows-Rechner `DL.exe` (die aktuelle, ungepatchte Version: `DL.exe` oder `DL.exe.orig`, je nach
   Zustand) in **dnSpy** oeffnen und mit "Datei -> Export to Project..." nach z.B. `~/.klaus/decomp-neu`
   exportieren (Ordner zippen und uebergeben). Die Klassen liegen unter `tempbase2/Devices/Usb/`
   (`hid.cs`, `UsbCommand.cs`, `DataFactory.cs`) und `tempbase2/Monitor/CUSB.cs`.
   Der Export der Version 3.1.2 liegt zum Vergleich noch unter `~/.klaus/decomp` (falls vorhanden).
   Herstellercode: nicht weitergeben, nicht in oeffentliche Berichte kopieren.
2. **Stelle wiederfinden:** `grep -n "CreateFile\|1073741824\|FILE_FLAG_OVERLAPPED" hid.cs`. Gesucht wird
   der `CreateFile`-Aufruf fuer `ReadHandle` in `OpenDevice` mit dem Flag 1073741824.
   - Ist der Aufruf **unveraendert**, aber das Byte-Muster passt nicht (anderer Compiler, anderes Register):
     im neuen `DL.exe` mit Python nach `20 00 00 00 40` in der Naehe eines `call` suchen (Kontext um den
     Treffer ausgeben) und `PAT`/`PAT_DONE` in `patch-dl.py` entsprechend anpassen. Immer genau **einen**
     Treffer erzwingen (das Skript verweigert sonst absichtlich den Patch).
   - Hat der Hersteller die HID-Schicht **umgebaut** (andere Klasse, HidSharp, async/await, Overlapped mit
     eigener Struktur): den neuen Lesepfad verstehen (`BeginRead`/`ReadCompleted`/`Write` in `hid.cs`) und
     pruefen, ob der Fehler dort noch entsteht. Gegebenenfalls einen anderen Patchpunkt waehlen.
   - Hat der Hersteller den Fehler **behoben** (kein OVERLAPPED mehr): dann ist kein Patch noetig. Trotzdem
     mit Schritt 4 pruefen, ob der Shim allein reicht.
3. **Patch an einer Kopie testen** (nie zuerst am echten Prefix): `patch-dl.py` auf eine Kopie von `DL.exe`
   anwenden, Ergebnis mit `cmp -l` gegen das Original pruefen (es duerfen nur die 5 Bytes abweichen).
   Besser: Kopie des Prefix anlegen (`cp -a ~/.wine ~/.wine-test`) und dort testen, alles ueber
   `WINEPREFIX=~/.wine-test`. Vor Aenderungen am echten `~/.wine` den Benutzer fragen.
4. **Funktionstest** (Logger muss eingesteckt sein, kein tempbase in derselben Sitzung offen):
   ```
   WINEPREFIX=<prefix> WINEDEBUG=+hid,+timestamp TEMPBASE_HID_ALL=1 \
     LD_PRELOAD=~/.local/share/tempbase-shim/hidraw-delay.so \
     /opt/wine-devel/bin/wine "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\tempbase 2\tempbase 2.lnk" \
     > test.log 2>&1
   ```
   Nach ca. 60 s beenden (`wineserver -k`) und auswerten: Zaehle pro Enumerationszyklus die Zeilen
   `hid_internal_dispatch write output report` (Schreibzugriffe) und `deliver_next_report ... input report`
   (Antworten); ein Zyklus beginnt bei jeder `HidD_GetHidGuid`-Gruppe.
   - **Erfolg:** die ersten Zyklen haben 31 Writes und 31 Reads, danach folgen Zyklen mit je 1 Write/1 Read
     (Ueberwachungsmodus). Im tempbase-Fenster zeigt die Statusleiste ein verbundenes Geraet, "Download"
     zeigt einen Fortschrittsbalken (der Benutzer muss das ansehen und bestaetigen).
   - **Fehlschlag:** dauerhaft Zyklen mit nur 4 Writes = derselbe Fehler wie zuvor (Patch wirkt nicht).
   Detaildiagnose: die Klasse `hid.cs` mit Wines Mono `mcs.exe` (`~/.wine/drive_c/windows/mono/mono-2.0/lib/mono/4.5/mcs.exe`,
   Aufruf mit `wine`, Option `-platform:x86`) zusammen mit einem kleinen Testprogramm kompilieren, in
   dem die Ausnahmen ausgegeben werden (`catch (Exception __e) { Console.WriteLine(__e); }`). Das hat den
   IOException-997-Fehler sichtbar gemacht. Wichtig: als **x86** bauen, sonst findet SetupDi keine Geraete.
5. **Werkzeuge aktualisieren, an beiden Stellen:**
   - `~/.local/share/tempbase-shim/patch-dl.py` (wird vom Starter benutzt)
   - eingebettete Kopie in `install-tempbase-wine.sh` (Abschnitt `cat > "$SHIM_DIR/patch-dl.py"`), damit
     Neuinstallationen das neue Muster bekommen.
   Danach `install-tempbase-wine.sh --pruefen` und einen echten Start ueber das Startmenue testen.
   Falls der Shim geaendert werden muss: `hidraw-delay.c` neu bauen
   (`gcc -O2 -shared -fPIC -o hidraw-delay.so hidraw-delay.c -ldl -lpthread`), ebenfalls im Skript nachziehen.

## Sonderfall: "Device disconnected" nach einem Update, OHNE jede Fehlermeldung, obwohl `--pruefen` den Patch als aktiv zeigt

Gefunden und behoben am 2026-09-22 - bitte nicht neu untersuchen, nur ausfuehren:

**Ursache:** tempbase laedt bei der Selbstaktualisierung ein VOLLES, nicht-stilles Inno-Setup-Installationsprogramm
herunter und startet es ohne Silent-Parameter (`Process.Start(setupFileSavePath)` in `ShowNewVersion.cs`). Dieses
Setup legt bei jedem Lauf eine Verknuepfung auf dem Windows-"Desktop" an (`C:\users\Public\Desktop\tempbase 2.lnk`).
Wine erzeugt daraufhin ein EIGENES, zweites `.desktop` direkt auf dem echten Schreibtisch (`xdg-user-dir DESKTOP`,
z.B. `~/Schreibtisch` - **unabhaengig von `XDG_DATA_HOME`**, ein Sandbox-Override wirkt hier NICHT), mit einem
reinen `wine "...lnk"`-Aufruf ohne unseren Starter. Ein Doppelklick auf dieses (neue) Schreibtisch-Symbol umgeht
damit Patch und Shim, OHNE jede Meldung (der Starter wird ja gar nicht aufgerufen) - einfach wieder
"Device disconnected".

**Bereits behoben in `install-tempbase-wine.sh`:** sucht seitdem tempbase-`.desktop`-Dateien zusaetzlich im echten
Schreibtisch-Verzeichnis und biegt beide (Startmenue + Schreibtisch) auf den Starter um. Laeuft seitdem auch OHNE
Installationsdatei als reiner Reparaturlauf (`./install-tempbase-wine.sh --ja`, ggf. `--ohne-apt`), wenn tempbase
schon installiert ist. `--pruefen` zeigt ein defektes Schreibtisch-Symbol als
`[FEHLT] Schreibtisch-Symbol ohne Starter`.

**Zusaetzlich gehaertet (ebenfalls 2026-09-22):** Beide `.desktop`-Dateien (Startmenue + Schreibtisch) werden nach
dem Fix mit `chmod 444` schreibgeschuetzt. Empirisch mit dem echten, direkt vom Hersteller-Server geladenen
Update-Paket getestet: Wine/winemenubuilder ueberschreibt eine bestehende `.desktop`-Datei per open+truncate
(nicht per unlink+rename) und haelt sich daher an fehlende Schreibrechte - ein erneuter Update-Lauf liess die
schreibgeschuetzte Datei (Inode, Rechte, Inhalt) unveraendert, keine Fehlermeldung im Setup-Log. Ein Deinstallieren
(unlink, braucht nur Verzeichnisrechte) bleibt davon unberuehrt moeglich. `install-tempbase-wine.sh` hebt den
Schreibschutz bei einer eigenen Reparatur selbst kurz auf (`chmod u+w` vor dem Schreiben) und setzt ihn danach
wieder. Damit ist ein erneuter Lauf nach jedem Update nur noch ein zusaetzliches Sicherheitsnetz, keine notwendige
Voraussetzung mehr.

**Ebenfalls mit dem echten Update-Paket ueberprueft:** Der Windows-Startmenue-Eintrag selbst wird von einer
tempbase-Selbstaktualisierung NICHT neu geschrieben (Zeitstempel vor/nach einem echten Versionssprung 3.1.2 -> 3.1.4
identisch bis auf die Nanosekunde) - betroffen ist ausschliesslich das neu angelegte Schreibtisch-Symbol. Die
Update-URL/-XML steht fest in `Tasks/AutoUpgrade/CCheckNewVersionTask.cs`
(`http://www.tempmate.com/downloads/tempbase2/Server.xml`, darin `ReleaseUrl`) und laesst sich damit fuer Tests
direkt herunterladen, ohne den Update-Dialog in der laufenden Anwendung anklicken zu muessen.

**Wenn es trotzdem wieder auftritt:**
1. `install-tempbase-wine.sh --pruefen`; bei "Schreibtisch-Symbol ohne Starter" einfach
   `install-tempbase-wine.sh --ja` (ohne Installationsdatei) erneut ausfuehren.
2. Falls `xdg-user-dir DESKTOP` nicht das tatsaechlich benutzte Verzeichnis liefert: von Hand suchen mit
   `grep -rl "tempbase" ~/Desktop ~/Schreibtisch ~/.local/share/applications 2>/dev/null | xargs grep -L "tempbase-start.sh"`.
   ACHTUNG (selbst hier hineingetappt): Ist der Schreibtisch-Ordner ein Symlink (z.B. auf einen Cloud-Sync-Ordner,
   `readlink ~/Schreibtisch` zeigt es), findet `find <symlink> ...` OHNE `-L` darin NICHTS - vorher mit
   `readlink -f` auf den echten Pfad aufloesen (macht `install-tempbase-wine.sh` bereits fuer `DESKTOP_DIR`).
3. Legt tempbase kuenftig weitere Verknuepfungsorte an (Schnellstart, angepinnt): gleiches Muster - Datei finden,
   `chmod u+w`, `Exec=` per `sed` auf `"$SHIM_DIR/tempbase-start.sh"` umbiegen, `chmod 444`.

## Hinweise

- Sudo-Befehle kann die Sitzung nicht selbst ausfuehren (Passwort). Der Benutzer tippt sie mit `! <befehl>`.
- Den Benutzer vor Aenderungen am echten Prefix, an `.desktop`-Dateien und am Systempaketstand fragen.
- Nach jedem Test tempbase-/wineserver-Prozesse beenden (`WINEPREFIX=... wineserver -k`) und Testkopien
  des Prefix (je ca. 2 GB) wieder loeschen.
- Wenn ein Wine-Update oder ein neues Mono etwas anderes bricht: zuerst pruefen, ob
  `IOException 997` noch auftritt (Testprogramm oben). Ein Bericht dazu an das Wine-Mono-Projekt liegt als
  `wine-mono-bugreport-filestream-overlapped.md` samt `Repro.cs` vor (Stand 2026-09-21, noch nicht eingereicht).
  Wird der Fehler in Wine Mono behoben, entfaellt der DL.exe-Patch.
MDEOF

# Biegt eine .desktop-Datei auf den Starter um und macht sie danach schreibgeschuetzt
# (chmod 444). Wine/winemenubuilder ueberschreibt eine bestehende .desktop-Datei per
# open+truncate (nicht per unlink+rename) - das respektiert normale Dateirechte, ein
# Loeschen beim Deinstallieren (unlink, nur Verzeichnisrechte noetig) bleibt moeglich.
# Damit bleibt unsere Umleitung auch dann bestehen, wenn tempbase/Wine spaeter versucht,
# dieselbe Datei erneut zu erzeugen (siehe "Sonderfall" oben).
fix_desktop_file() {
    local df="$1" backup="$2"
    chmod u+w "$df" 2>/dev/null || true
    cp -n -p "$df" "$backup" 2>/dev/null || true
    sed -i -E "s#^(Exec(\[[a-z_A-Z@]+\])?=).*#\1\"$SHIM_DIR/tempbase-start.sh\"#" "$df"
    chmod 444 "$df"
}

mkdir -p "$APPS_DIR"
DESKTOP_FILES=$(find "$APPS_DIR" -iname "*tempbase*.desktop" 2>/dev/null | grep -vi -e entfernen -e uninstall -e remove -e deinstall || true)
if [ -n "$DESKTOP_FILES" ]; then
    while IFS= read -r DF; do
        fix_desktop_file "$DF" "$SHIM_DIR/$(basename "$DF").orig"
        echo "    Menue-Eintrag angepasst und schreibgeschuetzt: $DF"
    done <<< "$DESKTOP_FILES"
else
    ICON=$(find "$DATA_HOME/icons" -iname "*tempbase*" -o -iname "*DL*.png" 2>/dev/null | head -1 || true)
    cat > "$APPS_DIR/tempbase-2.desktop" <<DEOF
[Desktop Entry]
Type=Application
Name=tempbase 2
Comment=TempMate-Logger auslesen (Wine)
Exec="$SHIM_DIR/tempbase-start.sh"
Icon=${ICON:-wine}
Categories=Utility;
StartupNotify=true
DEOF
    chmod 444 "$APPS_DIR/tempbase-2.desktop"
    echo "    Wine hat keinen Menue-Eintrag angelegt; erstellt: $APPS_DIR/tempbase-2.desktop"
fi
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true

# Schreibtisch-Symbol: Wine legt dies unabhaengig von XDG_DATA_HOME direkt in $DESKTOP_DIR
# an, sobald irgendeine Windows-Verknuepfung unter "...\Desktop" liegt (z.B. durch das
# volle, nicht-stille Setup der tempbase-Selbstaktualisierung). Falls vorhanden, ebenfalls
# auf den Starter umbiegen - sonst zeigt ein Doppelklick darauf ungepatchtes tempbase.
# Der Schreibschutz (s.o.) verhindert dabei, dass Wine dieses Symbol beim naechsten
# Update erneut ueberschreibt (getestet: Wine ueberschreibt per open+truncate, nicht per
# unlink+rename, und respektiert daher fehlende Schreibrechte).
if [ -d "$DESKTOP_DIR" ]; then
    DESKTOP_ICON_FILES=$(find "$DESKTOP_DIR" -maxdepth 1 -iname "*tempbase*.desktop" 2>/dev/null | grep -vi -e entfernen -e uninstall -e remove -e deinstall || true)
    if [ -n "$DESKTOP_ICON_FILES" ]; then
        while IFS= read -r DF; do
            fix_desktop_file "$DF" "$SHIM_DIR/schreibtisch-$(basename "$DF").orig"
            echo "    Schreibtisch-Symbol angepasst und schreibgeschuetzt: $DF"
        done <<< "$DESKTOP_ICON_FILES"
    fi
fi

# ------------------------------------------------------- 6. Pruefung
info "6/6: Abschlusspruefung"
FEHLER=0
pruefen || FEHLER=1

echo ""
echo "==> Fertig."
if [ "${NEUANMELDEN:-0}" = 1 ]; then
    echo "    WICHTIG: Fuer die Gruppe plugdev einmal ab- und wieder anmelden (oder neu starten),"
    echo "    sonst hat tempbase keinen Zugriff auf den USB-Logger."
fi
echo "    Logger einstecken (bei bereits eingestecktem Logger einmal aus- und wieder einstecken),"
echo "    tempbase 2 ueber das Startmenue starten. Die Verbindung braucht beim Start ca. 10 s."
echo "    Der Starter prueft bei jedem Start den USB-Patch und holt ihn nach einem tempbase-Update nach."
echo "    Start- und Schreibtisch-Symbol sind jetzt schreibgeschuetzt, damit eine tempbase-"
echo "    Selbstaktualisierung sie nicht wieder durch einen ungepatchten Aufruf ersetzen kann."
echo "    Sollte trotzdem mal wieder 'Device disconnected' ohne Fehlermeldung auftreten, hilft"
echo "    ein erneuter Lauf dieses Skripts, ohne Installationsdatei:  $0"
echo "    Spaeter pruefen:  $0 --pruefen"
exit "$FEHLER"
