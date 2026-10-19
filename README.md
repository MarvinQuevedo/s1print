# s1print

Developed by **[Marvin Quevedo](https://github.com/MarvinQuevedo)**.

Open-source driver for the **Luck Jingle S1** Bluetooth thermal printer
(the Xiamen Lujiang "LuckPrinter" family). The vendor offers no macOS driver for
the S1; s1print makes it show up as a normal printer on the Mac, so you can
print from Chrome, Preview or any app.

Status: works on macOS 13+ with an S1 (firmware V3.0.3). Linux and Windows are
planned; the core (`S1Kit`) has no Apple dependencies.

## How it works

```
App (Chrome, Preview…) ─► CUPS queue "S1 Bluetooth" (IPP Everywhere, no driver)
        ─► ippeveprinter (ships with macOS, started by S1Print.app)
        ─► s1print: decode Apple/PWG raster → scale to 384 dots → dither
        ─► Bluetooth RFCOMM ─► S1
```

`S1Print.app` lives in the menu bar. It publishes a driverless printer with
Apple's own `ippeveprinter` and handles every job itself. Because the job runs
inside the app, macOS applies the app's Bluetooth permission.

## Install

Download `S1Print-<version>.zip` from [Releases](https://github.com/MarvinQuevedo/s1print/releases),
unzip it and move **S1Print.app** to Applications. Releases from 0.3.4 on are
signed with a Developer ID and notarized by Apple, so macOS opens them normally.

From source:

```bash
./scripts/bundle.sh                 # builds build/S1Print.app
cp -R build/S1Print.app /Applications/
open /Applications/S1Print.app
```

1. Pair the printer in System Settings → Bluetooth (it shows up as `PPS1_XXXX`, with a keyboard icon).
2. Open S1Print and allow Bluetooth when macOS asks. `bundle.sh` signs with your
   first "Apple Development" identity (or `SIGN_IDENTITY`) so the permission is
   kept across rebuilds; an ad-hoc signature makes macOS ask again after each build.
3. The queue **S1 Bluetooth** is added on first launch. The menu-bar icon shows the
   printer's battery and paper state, prints a test page, and adds or removes the
   queue (*Installed in macOS Printers*).

## Settings

Menu-bar icon → **Settings…** (⌘,):

| Setting | Default | What it does |
|---|---|---|
| Bluetooth printer | Automatic | Pick one paired S1 when you have several |
| Darkness | Medium | Light, medium or dark printing |
| Fit content to paper width | On | Crop empty side margins and fill the 48 mm head |
| Printer name | S1 Bluetooth | Name shown in print dialogs |
| Installed in macOS Printers | On | Add or remove the print queue |
| Open at login | Off | Start S1Print when you log in |
| Share on the local network | **Off** | Off: the print server listens on this Mac only (127.0.0.1). On: other devices on your network can find and use the printer |

Settings live in `~/Library/Application Support/s1print/settings.json`.

## Paper sizes

| Size | Use |
|---|---|
| 58 mm roll (58 × 600 mm, default) | Receipts and tickets: blank space above and below is cut off |
| 80 mm roll (80 × 600 mm) | 80 mm receipts, scaled to the 48 mm head |
| 58 × 30 / 40 / 50 / 80 mm | Labels and stickers |

There is also a **Custom** size (48–80 mm wide, up to 600 mm long). On roll sizes
s1print crops empty side margins and scales the content to the full 48 mm head,
because browsers often lay a receipt out narrower than the paper; blank pages
are skipped. The printer asks apps for 406 dpi so small text is drawn with enough
detail and then reduced to the 203 dpi head.

## Command line

The CLI must run through the app bundle (for the Bluetooth permission); `scripts/s1print` does that:

```bash
scripts/s1print status
scripts/s1print test
scripts/s1print print ticket.pdf --density 2
scripts/s1print preview ticket.pdf out.png   # what would be printed, no Bluetooth
```

## Protocol

See [docs/PROTOCOL.md](docs/PROTOCOL.md). Thanks to
[fichero-printer](https://github.com/0xMH/fichero-printer) for documenting the
LuckPrinter command family.

## Author

Marvin Quevedo — [github.com/MarvinQuevedo](https://github.com/MarvinQuevedo)

## License

MIT. Not affiliated with Luck Jingle or Xiamen Lujiang Technology.
