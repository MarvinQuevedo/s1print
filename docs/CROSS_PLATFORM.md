# Cross-platform plan: Linux and Windows

Status: plan, written 18 Oct 2026, after macOS 0.3.5. Nothing below is built yet.

## 1. Goal

The S1 shows up as a normal printer on Linux and Windows, as it does on macOS
today: any app prints to it, with no vendor driver, the same paper sizes and
the same output quality.

## 2. What we have, and what is portable

| Layer | Today | Portable? |
|---|---|---|
| `S1Kit`: raster decoding (PWG `RaS2`, Apple `UNIRAST`), fit to width, trim, blank-run cap, dithering, S1 command encoding | Pure Swift, Foundation only | **Yes**, unchanged |
| Rendering of PDF and images for the CLI (`Renderer`) | CoreGraphics / ImageIO | No |
| Bluetooth (`BluetoothTransport`) | IOBluetooth RFCOMM | No |
| Print server | Apple's `ippeveprinter`, run by the app | No (macOS/CUPS only) |
| UI: menu bar, Settings, About | AppKit + SwiftUI | No |
| Settings, media list, IPP attributes (`Settings.swift`) | Foundation | Yes |

Everything that touched paper during testing (the protocol, the "OK" wait,
pacing, 406 dpi input, fit to content, trimming) lives in `S1Kit` and the job
sender. Those rules carry over as they are.

## 3. Architecture: a Printer Application on every OS

Keep the shape that works on macOS. A local IPP Everywhere server makes the OS
add a driverless printer; each job is decoded by S1Kit and sent over Bluetooth.

```
App ─► OS print system ─► IPP (localhost) ─► s1print server
        (CUPS / Windows        │                 │
         IPP Class Driver)     │                 ├─ S1Kit: raster → 384-dot bitmap → S1 commands
                               │                 └─ Transport: macOS IOBluetooth | Linux RFCOMM socket | Windows COM port
```

Decision: **write our own small IPP server in Swift** and use it on all three
platforms, replacing `ippeveprinter` on macOS too.

- `ippeveprinter` does not exist on Windows and is not packaged everywhere on Linux.
- One server means one set of attributes (`media-col-database`, 406 dpi,
  `pwg-raster` / `urf`), one job pipeline, and one place to fix bugs.
- Scope is small: IPP/1.1–2.0 over HTTP on 127.0.0.1, the operations
  `Get-Printer-Attributes`, `Validate-Job`, `Print-Job`, `Create-Job` +
  `Send-Document`, `Get-Jobs`, `Get-Job-Attributes`, `Cancel-Job`, and the
  document formats `image/pwg-raster` and `image/urf`. No PDF input: the
  client rasterizes, as it does today.
- Implementation: SwiftNIO (runs on macOS, Linux and Windows) and an IPP
  encoder/decoder in the core. Test it with `ipptool` and the IPP Everywhere
  self-certification suite (`ipp-everywhere.test`).

Keep `ippeveprinter` on macOS until the new server passes the same tests, then
switch.

### Package layout

```
Sources/
  S1Kit/           portable: raster, dither, protocol, job builder (exists)
  S1IPP/           portable: IPP codec + printer server + job queue (new)
  S1Transport/     protocol PrinterTransport + one file per OS (new)
  s1print-mac/     macOS app: AppKit/SwiftUI UI, IOBluetooth (exists, renamed)
  s1print-linux/   Linux daemon + CLI (new)
  s1print-win/     Windows tray app + CLI (new)
```

`PrinterTransport`: `open()`, `write(_:)`, `query(_:wait:)`, `waitFor(_:timeout:)`,
`close()`. Every implementation keeps the macOS rules: a ~5 s connect timeout,
waiting for the "OK" of `10 FF F1 45` (not the first "OK"), no pacing below
the print speed, and a watchdog on stuck commands.

## 4. Linux

### Printing system

CUPS. The modern route is a **Printer Application** (the model CUPS 2.5/3.x
and the OpenPrinting snaps use): our IPP server registers over DNS-SD and CUPS
adds it as an IPP Everywhere queue (`lpadmin -p S1_Bluetooth -E -v
ipp://localhost:8631/ipp/print -m everywhere`, the same command as on macOS).

Alternative considered: [PAPPL](https://www.msweet.org/pappl/), the C framework
behind most Printer Applications. It would give us the IPP server, web UI and
DNS-SD for free, but it is C and Linux-first. It is a good fallback if our own
server stalls; S1Kit would then be called through a small C shim, or ported.

Not chosen: a classic CUPS filter (`rastertos1`) + PPD + backend. It is
simpler on Linux alone, but it does not help Windows, and CUPS is retiring PPD
drivers.

### Bluetooth

- Classic SPP over BlueZ: an `AF_BLUETOOTH` / `BTPROTO_RFCOMM` socket to the
  printer's address on channel 1, from Glibc. No extra library.
- Pairing stays with the desktop's Bluetooth settings (`bluetoothctl pair`).
- Finding the printer: paired devices whose name starts with `PPS1`, `S1_` or
  `LuckP`, through BlueZ's D-Bus API (`org.bluez.Device1`), or the address from
  settings.
- Permissions: the user must be allowed to open RFCOMM sockets (normally yes
  on desktop distros). The service runs as the user, not as root.

### Running and packaging

- A `systemd --user` service runs the server at login. CLI: `s1print status`,
  `test`, `print`, `preview`, as on macOS.
- Settings: `~/.config/s1print/settings.json` (same keys).
- UI: none at first; settings through the CLI and the IPP server's small web
  page. A tray icon (GTK / libappindicator) can come later.
- Packages: `.deb`, `.rpm`, and an AppImage or Flatpak. A Flatpak needs the
  Bluetooth socket permission (`--allow=bluetooth`).
- Rendering for the CLI (PDF and images): Poppler (`pdftoppm`) or cairo, or
  print through the system queue and let CUPS rasterize.

### Tests

- Real Linux with Bluetooth. WSL has no Bluetooth, so a laptop or a USB
  Bluetooth dongle on a Linux machine is needed.
- Print the DTE ticket PDF from Chrome and Firefox, and a test page; compare
  with the macOS print.
- `ipptool -t ipp://localhost:8631/ipp/print ipp-everywhere.test`.

## 5. Windows

### Printing system

Windows 10 21H2+ and Windows 11 have the **Microsoft IPP Class Driver**: an IPP
Everywhere printer is added with no vendor driver. Windows normally finds IPP
printers on the network by mDNS/WS-Discovery. For a server on `localhost`,
add the printer from our app:

- PowerShell: `Add-Printer -Name "S1 Bluetooth" -PortName ...` with an IPP
  port, or "Add a printer" → "Select a shared printer by name" →
  `http://localhost:8631/ipp/print`.
- Check whether the class driver accepts a loopback IPP URL in every edition;
  if it does not, advertise on the LAN while installing, or register through
  the Windows print APIs. **This is the main unknown and the first spike.**

Windows sends **PWG raster** to IPP Class Driver printers, which S1Kit already
decodes. Confirm the resolution it picks: we advertise 406 dpi only.

Not chosen: a v4 or v3 Windows printer driver (XPS/GDI rendering plus an INF
package and driver signing). Much more work, and Microsoft is moving third-party
printing to the IPP class driver and "Print Support Apps".

### Bluetooth

- When an SPP device is paired, Windows creates an **outgoing COM port**
  (Settings → Bluetooth → More Bluetooth options → COM Ports). The transport
  writes to `\\.\COMn` with `CreateFile` / `WriteFile`.
- Better long term: Winsock `AF_BTH` / `BTHPROTO_RFCOMM` straight to the
  device, which does not depend on the user creating a COM port.
- The same rules apply: connect timeout, wait for the final "OK", no pacing
  below print speed.

### Running and packaging

- A tray app (Win32 `Shell_NotifyIcon`, or a small WinUI app) starts the
  server, shows the printer's status, and opens a Settings window with the same
  options as macOS.
- Start at login: a Run key or a Startup task.
- Settings: `%APPDATA%\s1print\settings.json`.
- Installer: MSIX or an Inno Setup/WiX `.exe`. Sign it with a code-signing
  certificate, the Windows counterpart of the Developer ID, or SmartScreen will
  warn on download.
- Swift on Windows: the official toolchain works and Foundation is available;
  the UI goes through `WinSDK` interop. If Swift UI work on Windows turns out
  too costly, write the tray app in C# and call a Swift (or C-ABI) core.

### Tests

- Marvin's Windows PC (192.168.18.20) has Bluetooth: pair the S1 there.
- Print from Edge, Chrome and Word; the DTE ticket; a test page.
- Check that Windows does not split long receipts into pages (the 58 × 600 mm
  roll size) and that it honors 406 dpi.

## 6. Phases

| Phase | Work | Done when |
|---|---|---|
| 0 | Split the package: `S1Kit` builds on Linux (CI on Ubuntu), `PrinterTransport` protocol, macOS transport moved behind it | `swift build` and the tests pass on Linux |
| 1 | `S1IPP`: our IPP server, tested with `ipptool` on macOS against the current behaviour | The macOS app works with our server instead of `ippeveprinter`, same prints |
| 2 | Linux: RFCOMM transport, `systemd --user` service, CLI, packages | The DTE ticket prints from Chrome on Linux |
| 3 | Windows spike: IPP class driver on a loopback URL, PWG raster resolution | A test page from Notepad reaches our server on Windows |
| 4 | Windows: COM / AF_BTH transport, tray app, installer, signing | The DTE ticket prints from Chrome on Windows |
| 5 | Shared polish: web settings page served by the IPP server, auto-update, docs | Same Settings on all three |

## 7. Risks and open questions

- **Windows and loopback IPP**: whether the IPP Class Driver adds a printer at
  `http://localhost` without network discovery (phase 3 answers it).
- **Swift on Windows UI**: Swift is fine for the core and server; the tray UI
  may be easier in C#.
- **Linux sandboxes**: Flatpak and Snap need explicit Bluetooth access.
- **Other LuckPrinter models**: the start/stop commands differ between
  families (Lujiang `10 FF F1 03/45`, AiYin `10 FF FE 01/45`). Read the model
  string (`10 FF 20 F0`) and pick the family, instead of assuming the S1.
- **Head width**: the S1 is 48 bytes (384 dots). Other models differ; make it
  per model.
- **Signing**: macOS uses a Developer ID today; Windows needs its own
  code-signing certificate.
