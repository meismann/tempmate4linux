# tempmate4linux

Run **tempbase 2** — the Windows software for TempMate USB temperature/humidity
loggers — on Linux under [Wine](https://www.winehq.org/), with a working USB
connection to the logger.

Official software and logger downloads:
**https://www.tempmate.com/en-us/resources/download/**

This is an **unofficial, community project**. It is not affiliated with, endorsed
by, or supported by TempMate. Use at your own risk (see [Disclaimer](#disclaimer)).

## The problem this solves

tempbase 2 runs under Wine, but every action that talks to the USB logger
("Download", "Full Data", "Logger Setup", …) fails immediately with
**"Device disconnected"**, even though the logger is plugged in and working fine.

Two independent causes, both worked around here:

1. **A Wine Mono bug.** tempbase 2 opens the logger's USB HID handle with
   `FILE_FLAG_OVERLAPPED`, then reads from it through a synchronous .NET
   `FileStream`. Under Wine Mono, a read that would need to wait for data throws
   `IOException: Win32 IO returned 997` (`ERROR_IO_PENDING`) instead of completing
   asynchronously. tempbase 2 silently swallows that exception and gives up on the
   connection after only 4 of the 31 packets it needs to exchange with the logger,
   so it never actually connects. `install-tempbase-wine.sh` patches this out of
   `DL.exe` (5 bytes, one IL instruction) — see the script's own comments for the
   exact bytes and how it locates them.
2. **A timing issue in the logger itself.** It doesn't answer a second request if
   it arrives less than ~300 ms after the previous one, while tempbase 2's normal
   polling cycle sends requests every ~80 ms. An `LD_PRELOAD` shim built by the
   script adds the missing delay on writes to the logger's `/dev/hidraw*` device.
3. tempbase 2 also **updates itself** (a full, non-silent installer, launched from
   inside the running app), which overwrites the patched `DL.exe` and creates a
   fresh, unpatched Desktop shortcut every time. The installer's launcher script
   re-applies the `DL.exe` patch on every start and write-protects both the Start
   Menu and Desktop `.desktop` files against being silently overwritten again.

None of this is TempMate's fault as such — the root cause is arguably a Wine Mono
bug in how it implements overlapped `FileStream` reads. A bug report for
[wine-mono](https://gitlab.winehq.org/mono/wine-mono) is drafted but not filed yet;
if someone wants to pick that up, see the "The cause" and "Procedure for a new
tempbase version" sections of `tempbase-wine-REPAIR.md` for the technical background
and how the error was made visible.

## The two files

- **`install-tempbase-wine.sh`** — the actual installer/fixer. Run it with the
  path to TempMate's official `tempbase 2 Vx.x.x.exe` installer to set up Wine,
  the udev rule for the logger, and tempbase 2 from scratch; run it again with no
  argument any time afterwards (e.g. after a tempbase self-update) to re-check and
  re-apply the fix. `./install-tempbase-wine.sh --check` checks the current state
  without changing anything, and `./install-tempbase-wine.sh --help` prints all
  options. The script is self-documenting — read the comment header for the full
  list of what each step does and why.

- **`tempbase-wine-REPAIR.md`** — a troubleshooting brief, written to be handed
  to an AI coding assistant (it was developed with
  [Claude Code](https://claude.com/claude-code)) rather than to a human. If a
  future tempbase 2 update changes the code enough that the automatic patch no
  longer applies, this file has the accumulated findings (exact IL byte pattern,
  what's already been ruled out, how to get a new decompile, how to test a fix)
  so that debugging it doesn't have to start from zero. Human readers are welcome
  too, of course; it also serves as documentation of *why* the script does what
  it does.

## Tested setup

Developed and verified working (including a full USB download of logger data)
on:

| | |
|---|---|
| Distro | Linux Mint 22.3 ("Zena", based on Ubuntu 24.04 "noble") |
| Wine | `winehq-devel` 11.17 and 11.18 (from the [WineHQ apt repository](https://wiki.winehq.org/Ubuntu)) |
| Wine Mono | 10.4.1 and 11.3.0 — either works, version doesn't matter for this fix |
| tempbase 2 | 3.1.2 (fresh install) and self-updated to 3.1.4 |
| Logger | TempMate USB logger, USB ID `04d8:0015` |
| Machines | Intel Celeron J3160 and Intel Core i5-8365U, both x86_64 |

`winehq-stable` (as opposed to `winehq-devel`) 11.0 has a separate, additional USB
I/O bug and is not supported by this script — it installs `winehq-devel` instead.
Other Debian/Ubuntu-based distros with the WineHQ repository available should
work but haven't all been tested; reports welcome either way.

## Usage

```
./install-tempbase-wine.sh "/path/to/tempbase 2 V3.1.2.exe"   # first install
./install-tempbase-wine.sh                                     # re-check/repair later
./install-tempbase-wine.sh --check                              # check only, no changes
./install-tempbase-wine.sh --help
```

Requires a Debian/Ubuntu-based distro with `apt` and `sudo`. Pass `--yes` to skip
confirmation prompts and `--no-apt` to skip all system-level changes (package
installation, udev rule, group membership) and only touch the Wine prefix and
tempbase 2 itself.

## Contributing

Forks, other logger models, other distros, other tempbase versions — all welcome.
Particularly useful contributions:

- Confirming (or fixing) this on other Debian/Ubuntu derivatives, or other Wine
  versions.
- Updating the `DL.exe` byte pattern for newer tempbase 2 releases (see
  `tempbase-wine-REPAIR.md`).
- Filing and following up on the Wine Mono bug report mentioned above — if that
  gets fixed upstream, the `DL.exe` patch in this script becomes unnecessary.
- Support for other TempMate logger models (different USB VID/PID than
  `04d8:0015`).

Please open an issue or pull request.

## Disclaimer

This script downloads and runs Wine Mono, and modifies (byte-patches) TempMate's
`DL.exe` executable to work around what looks like a Wine Mono bug. It is provided
as-is, with no warranty of any kind, in the hope that it's useful to others in the
same situation. It is not affiliated with, endorsed by, or supported by TempMate.
Use it at your own risk, and always keep your own backups of any data recorded by
your logger. `DL.exe.orig` (the unpatched original) is kept alongside the patched
file for anyone who wants to revert.

Copyright (c) 2026 Martin Eismann under MIT-License
