# S1Print: a driverless macOS printer for the Luck Jingle S1 Bluetooth thermal printer

Marvin Quevedo · October 2026 · [github.com/MarvinQuevedo/s1print](https://github.com/MarvinQuevedo/s1print)

## Abstract

S1Print makes a Luck Jingle S1 portable thermal printer appear as an ordinary macOS printer, so any app can print to it over Bluetooth with no vendor driver. The vendor publishes no macOS driver for the S1. We reverse-engineered its command set from a probe of the device and from a sister project, wrapped it in a local IPP Everywhere print server, and solved a chain of practical problems:

- a Bluetooth link the printer drops unless a serial channel is opened;
- macOS privacy rules that tie Bluetooth access to an app bundle;
- jobs that ended early;
- receipts that browsers lay out narrow or place at the bottom of the page;
- small text that broke up when converted to black and white.

A 58 × 164 mm electronic-invoice ticket now prints from Chrome or Safari with the same quality as the vendor's mobile app. The release is signed with a Developer ID and notarized by Apple.

## 1. The device and the gap

| Property | Value |
|---|---|
| Printer | Luck Jingle S1, "Mini Sticker Printer" (Xiamen Lujiang Technology Co., Ltd.) |
| Model string | `S1_LYiN48D_GY`, firmware V3.0.3 |
| Printhead | 384 dots per line (48 bytes), 203 dpi, 48 mm printable on 56–58 mm paper |
| Link | Classic Bluetooth, Serial Port Profile (SPP), RFCOMM channel 1; also advertises BLE |
| Vendor software | Mobile apps; a macOS app; macOS and Windows CUPS drivers for the A4 models only |

macOS only lists a Bluetooth printer by itself when the printer speaks the Bluetooth printing profile (HCRP). The S1 speaks only SPP: a plain serial stream. So the Mac pairs it, shows it with a generic keyboard icon, creates `/dev/cu.PPS1_XXXX`, and offers no way to print.

## 2. Reverse engineering

**The vendor's macOS app does not drive the printer.** Unpacking `Luckjingle-mac.pkg` without running it showed a Flutter app. Its Dart code renders a PDF and hands it to a system printer through `lpstat` and a PPD found in `/Library/Printers/PPDs`, which a separate CUPS driver would install. The vendor's driver catalogue (`/api/apis/public/actuate`) lists 33 models, all A4 or label printers, and no S1. The app holds no Bluetooth code and no S1 protocol.

**The S1 belongs to the LuckPrinter family.** The open-source [fichero-printer](https://github.com/0xMH/fichero-printer) project documented the command set of the AiYin D11s, which ships on the same "LuckPrinter" SDK. That SDK notes two print-framing variants: AiYin and Lujiang. The S1 is a Lujiang device.

**Probing the device confirmed it.** Read-only queries over the serial port returned the model, firmware, serial, battery and status. A 48-byte-wide test pattern framed with the Lujiang start and stop commands printed correctly.

## 3. The protocol

| Bytes | Purpose | Answer |
|---|---|---|
| `10 FF 20 F0` / `F1` / `F2` | Model / firmware / serial | ASCII string |
| `10 FF 50 F1` | Battery | `00 nn` (percent) |
| `10 FF 40` | Status bitmask: `01` printing, `02` cover open, `04` out of paper, `08` low battery | one byte |
| `10 FF 70` | All info, pipe-separated | ASCII |
| `10 FF 10 00 nn` | Density 0–2 | `OK` |
| `00` × 12 | Wake | — |
| `10 FF F1 03` | Start print (Lujiang) | — |
| `1D 76 30 00 30 00 yL yH` + bits | Raster block (ESC/POS GS v 0), 48 bytes per row, 1 bit per dot, MSB left, 1 = black | — |
| `1B 4A nn` | Feed nn dots | — |
| `10 FF F1 45` | End print | `OK` when the job has printed |

A job is density, wake, start, raster blocks of up to 255 rows, a feed, and end.

## 4. Architecture

```
App (Chrome, Safari, Preview…)
  └─ macOS printing (CUPS) ── queue "S1 Bluetooth", IPP Everywhere, no driver
       └─ ippeveprinter on 127.0.0.1:8631   (Apple's tool, started by S1Print.app)
            └─ s1print <job file>           (same executable, one process per job)
                 ├─ S1Kit: decode raster → fit to 384 dots → black and white → S1 commands
                 └─ IOBluetooth RFCOMM channel 1 ──► S1
```

1. **S1Print.app** is a menu-bar app. It writes an attributes file and starts `ippeveprinter`, which ships with macOS and implements an IPP Everywhere printer. It then adds the CUPS queue with `lpadmin -m everywhere`, so the printer needs no PPD or driver.
2. **macOS rasterizes**. The print dialog sends each job as Apple Raster (`image/urf`) or PWG Raster, in 8-bit gray at the resolution and paper size the printer advertises.
3. **`ippeveprinter` runs `s1print` once per job** with the spooled file. Because that process descends from S1Print.app, macOS charges its Bluetooth access to the app's permission.
4. **S1Kit**, a platform-independent Swift module, turns the raster into printer commands. A thin macOS layer sends them over Bluetooth.

The same executable is also the command-line tool (`status`, `test`, `print`, `preview`) and the menu-bar app.

## 5. Bluetooth transport

**Open the serial channel directly.** The S1 accepts a Bluetooth connection, then drops it a few seconds later unless an RFCOMM channel is opened. Writing to `/dev/cu.PPS1_XXXX` worked once and later stopped opening a channel. S1Print opens RFCOMM channel 1 itself with IOBluetooth, after an SDP lookup of the "SPP slave" service, and writes in MTU-sized pieces of 240 bytes.

**Privacy permission lives in an app bundle.** macOS kills a process that touches Bluetooth unless the *responsible app* declares `NSBluetoothAlwaysUsageDescription`. A bare command-line binary, even one with an embedded Info.plist, inherits its launcher as the responsible app. So everything runs inside `S1Print.app`, and the CLI wrapper starts it through `open`.

**The permission follows the code signature.** An ad-hoc signature changes with every build, so macOS asked again after each rebuild. A stable identity (Apple Development, then Developer ID) keeps the grant.

**Wait for the right answer.** Both the density command and the end command answer `OK`. Closing the channel at the first `OK` cut the last 15 % of a receipt into noise. S1Print clears the buffer before sending the end command, waits for its `OK` (about 2 s after the last byte on a 164 mm ticket), and keeps the channel open another 1.5 s.

**Do not slow the data below the print speed.** Pacing at 9 kB/s let the head run dry mid-page and left white bands. Sending as fast as RFCOMM flow control allows prints cleanly: a full ticket takes about 12 s.

**Never hang.** A printer that is off made `openConnection` wait for minutes while holding the job lock. Connecting now uses a page timeout of about 5 s per attempt, and a watchdog ends a stuck status query after 40 s or a job after 10 minutes. Jobs and queries share a file lock, so only one talks to the printer at a time.

## 6. The print pipeline

| Step | What S1Kit does | Why |
|---|---|---|
| Decode | Reads PWG (`RaS2`) and Apple (`UNIRAST`) raster: 1-, 8-, 24- and 32-bit, PackBits line compression with line repeats | These are what IPP Everywhere clients send |
| Skip blank pages | Pages with no ink are dropped | Browsers often add empty trailing pages |
| Crop to content | One shared crop of empty side margins for the whole job | Safari drew a 58 mm ticket in 270 of 463 columns, so scaling the whole page printed it tiny |
| Fit to the head | Scale to 384 dots: area averaging when shrinking, bilinear when enlarging | Nearest-neighbour enlargement broke antialiased edges into jagged strokes |
| Trim and cap blank space | Remove white rows above and below on roll sizes; never send more than 20 mm of consecutive blank rows | macOS places a short page at the bottom of a long roll page: 440 mm of white once fed out before the ticket |
| Black and white | Threshold at 150 for text, Atkinson diffusion when more than 35 % of the inked pixels are mid-gray (photos) | A threshold above mid-gray keeps the antialiased edges of thin strokes black |
| Frame | Density, wake, start, `GS v 0` blocks of 255 rows, feed, end | The Lujiang print sequence |

**Input resolution matters most for small text.** At 203 dpi, receipt text arrives with glyphs 5–6 dots tall, and thin strokes vanish when converted to black and white. The printer advertises **406 dpi** only, so apps draw at twice the head's resolution and S1Kit shrinks. The same ticket became legible after this change.

## 7. macOS integration

**Paper sizes.** All sizes declare zero side margins: the page edge is the paper edge, and the whole width is scaled onto the head.

| Size | Use |
|---|---|
| 58 × 600 mm roll (default) | Receipts and tickets; blank space trimmed |
| 80 × 600 mm roll | 80 mm receipts, scaled to 48 mm |
| 58 × 30, 40, 50, 80 mm | Labels |
| Custom, 48–80 × 10–600 mm | Anything else |

The queue default must be set explicitly. Otherwise CUPS picked the 30 mm label and cut tickets to their last 3 cm.

**Local only by default.** `ippeveprinter` listens on every interface and advertises itself over Bonjour, so any device on the Wi-Fi could find the printer and print to it. S1Print starts it with `-n localhost -r off`: it binds to 127.0.0.1 and ::1 and is not advertised, unless the user turns on *Share on the local network*. A shared printer is advertised as "‹name› @ ‹Mac›", so the Mac does not list its own advert next to the local queue under the same name.

**Detecting the queue.** `lpstat -p NAME` also succeeds for a Bonjour printer of the same name. After the queue was removed, the app still saw it and only offered to remove it. S1Print now checks for the local queue's PPD in `/etc/cups/ppd/`.

**The app.** The menu shows the printer's name, battery and status, prints a test page, and adds or removes the queue with a confirmation bubble. Settings, also opened by launching the app again, covers:
- the printer choice;
- darkness;
- fit to width;
- printer name;
- install;
- open at login;
- network sharing.

Settings are read key by key, so a file from an older version keeps its values. Windows of a menu-bar app are brought forward explicitly, because recent macOS ignores `activate(ignoringOtherApps:)` for accessory apps.

## 8. Failures found on paper, and their fixes

| Symptom | Cause | Fix |
|---|---|---|
| Printer stopped answering after the first test | `/dev/cu` did not reopen an RFCOMM channel | Open RFCOMM through IOBluetooth |
| Tool killed on launch | No Bluetooth usage string in the responsible app | Run inside an app bundle |
| End of the ticket printed as noise | Channel closed at the density command's `OK` | Wait for the end command's `OK` |
| QR code split into bands | Data paced slower than the head prints | Let RFCOMM flow control set the pace |
| Ticket tiny, via the system | Page placed at the bottom of a 600 mm roll; 30 mm default size | Trim both ends; set the 58 mm roll as default |
| Metres of blank paper | Content at the bottom of a long page | Trim plus the 20 mm blank-run cap |
| Small text broken in Safari | 203 dpi input enlarged with nearest-neighbour | 406 dpi input, bilinear enlarging, threshold 150 |
| Permission asked on every print | Ad-hoc signature changes per build | Stable signing identity |
| "Remove" offered for a missing printer | Bonjour destination with the queue's name | Detect the local PPD; no advert unless shared |
| Settings window invisible | SwiftUI `Form` has no intrinsic height (73-pt window) | Fixed window size |

## 9. Distribution

Releases are zipped app bundles on GitHub. From 0.3.4 they are signed with a Developer ID, built with the hardened runtime and a secure timestamp, notarized with `notarytool`, and stapled, so Gatekeeper opens a downloaded copy without warnings (`source=Notarized Developer ID`). `scripts/release.sh` runs the whole sequence. Notary credentials stay in the macOS keychain.

## 10. Limitations and next steps

- Tested on one S1 with firmware V3.0.3. Other LuckPrinter models use other start and stop commands (AiYin: `10 FF FE 01` / `45`) and other head widths; the model string should select them.
- macOS only. Linux and Windows are planned around a shared IPP server and a per-OS Bluetooth layer: see [CROSS_PLATFORM.md](CROSS_PLATFORM.md).
- Output depends on what the app sends. A page laid out wider than the paper is still shrunk; the fix belongs in the page, for example a print stylesheet sized to 58 mm.

## References

- S1Print source and releases: [github.com/MarvinQuevedo/s1print](https://github.com/MarvinQuevedo/s1print)
- Protocol notes: [PROTOCOL.md](PROTOCOL.md)
- LuckPrinter family command set: [0xMH/fichero-printer](https://github.com/0xMH/fichero-printer)
- PWG 5100.14, IPP Everywhere; PWG 5102.4, PWG Raster Format
- Apple `ippeveprinter(1)` and `lpadmin(8)` manual pages
