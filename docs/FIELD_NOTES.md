# Field notes: what the S1 taught us on every platform

These are the lessons from printing real receipts on a Luck Jingle S1
(`S1_LYiN48D_GY`, firmware V3.0.3) from macOS, iOS, Android and Windows, and
from the web app whose tickets started this project
([Facta DTE](https://www.factadte.com), electronic invoicing for El Salvador).
Each item says what failed, why, and what fixed it. Details live in the linked
documents.

## The printer

| Lesson | Evidence | Where |
|---|---|---|
| Send a page as **one** `GS v 0` raster command with its full height. Splitting it into 255-row blocks makes the head stop at every block boundary when data arrives slowly (BLE), leaving a blank band about every 32 mm | Vendor SDK does one command per page; on iOS the bands disappeared with `rowsPerBlock` = 65535 | [LUCKPRINTER_SDK.md](LUCKPRINTER_SDK.md), [IOS_BLE_THROUGHPUT_PLAN.md](IOS_BLE_THROUGHPUT_PLAN.md) |
| With one raster command, the printer answers **`OK` before stop is sent**, and stop gets no reply of its own. Never clear the reply buffer between the last raster chunk and stop, or the job waits forever and the printer stays blue | Fixed in iOS `PrintExchange` (replies cleared before the last chunk) | iOS commit "finish the job when the raster reply arrives before stop" |
| Do **not** replace blank rows with `ESC J` paper feeds. The S1 feeds less than asked and lines overlap | Tested on paper, reverted | [IOS_BLE_THROUGHPUT_PLAN.md](IOS_BLE_THROUGHPUT_PLAN.md) |
| Density (`10 FF 10 00 n`) is a setting the printer keeps; the vendor app sends it only when the user changes it. Speed is never sent for this model | Vendor SDK | [LUCKPRINTER_SDK.md](LUCKPRINTER_SDK.md) |
| `FF01` replies `FF 01`/`FF 02`/`FF 03`/`FF 13`/`FF 04` mean out of paper, cover open, overheated (two codes) and low battery. The vendor app aborts the job on them | Vendor SDK. **Open:** s1print logs them and does not abort yet | [LUCKPRINTER_SDK.md](LUCKPRINTER_SDK.md) |

## Bluetooth Low Energy (iOS)

| Lesson | Evidence |
|---|---|
| `FF03` notifications are **credits**: `01 NN` adds NN packets you may send, `02 LL HH` sets the packet size (200 bytes on the S1). Writing without credits overruns the printer, which resets (blue light, power off) | Tested on the device; vendor SDK agrees |
| Third-party drivers that read `FF03 01 xx` as a status byte and pace writes with timers are wrong for this printer | [LUCKPRINTER_SDK.md](LUCKPRINTER_SDK.md) §Third-party drivers |
| BLE is slow (about 3.7 kB/s). A receipt takes 20–25 s to transfer; the printer copes as long as each page is one raster command | iOS diagnostics log |
| After a successful job, disconnect cleanly. Otherwise the printer keeps the link open and the app looks busy | iOS `closeAfterJob()` |

## Classic Bluetooth (macOS, Android, Windows)

- SPP is fast enough that 255-row blocks print cleanly, so those platforms
  keep them. If a platform ever moves to one command per page, apply the
  reply-ordering lesson above to its transport too: Android and Windows also
  clear replies before stop.
- The Android vendor app uses SPP for this printer, not BLE.

## Printing from web apps (the Facta DTE ticket)

The same ticket printed differently on each system until the web app sent a
PDF built for the 58 mm roll instead of an HTML page:

| Lesson | Fix in the web app |
|---|---|
| Browsers lay out HTML tickets at their own width and scale them, so text came out small or cut | Print desktop tickets from a PDF sized for the roll |
| Thermal printing needs more line spacing than the screen | Ticket line pitch 1.15 |
| A QR must be big enough to scan after dithering to 203 dpi | QR at 120 px on the ticket |
| Safari and Chrome differ in print margins and headers | Margins None, no headers or footers, 58 mm paper size |

Once the ticket was a proper PDF, macOS and Android printed it identically
from any browser.

## Recovering vendor behaviour

- The Android app (`com.dingdang.newprint`) decompiles with jadx; the iOS
  JinglePro binary is FairPlay-encrypted and was not read.
- Nothing from the vendor is copied into this repository, and native vendor
  code is never run. Steps in [LUCKPRINTER_SDK.md](LUCKPRINTER_SDK.md).

## Still open

1. Abort a job on `FF01` error replies, on every platform.
2. Decide whether the iOS diagnostics strategy picker stays visible.
3. Test other Luck Jingle models.
4. Try the zlib-compressed raster (`1F 10`) if BLE ever needs to be faster.
