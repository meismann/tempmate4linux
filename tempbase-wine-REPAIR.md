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
