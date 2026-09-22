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
