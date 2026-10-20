# What the vendor app does: Luck Jingle SDK findings

These notes come from reading the official Luck Jingle Android app (package
`com.dingdang.newprint`, version 2.7.23, XAPK from APKPure) on 20-Oct-2026,
decompiled with jadx 1.5.6. The printer code is the vendor SDK
`com.luckprinter.sdk_new`. The iOS app JinglePro uses the same SDK, but its
main binary is FairPlay-encrypted (`cryptid 1`), so it was not read. Its
unencrypted Objective-C metadata shows the same names (`compressWay`,
`zlibCompressData:windowBits:`, `speedList`).

Nothing from the vendor (code or binaries) is copied into this repository.
Where a statement was tested on our own S1 (`S1_LYiN48D_GY`, firmware V3.0.3),
it says so. Everything else is what the SDK does, not proven behaviour of the
printer.

## The result that fixed iOS

The SDK sends a whole page as **one** `GS v 0` command, with the full height
in `hL hH`. Before 20-Oct, s1print split pages into 255-row blocks.

Over classic SPP the blocks do no harm. Over BLE they do. Data arrives at
about 3.7 kB/s, so a 12 KB block takes about 3.3 s to arrive. The printer
stopped at every block boundary and left a blank band about every 32 mm,
roughly five per ticket.

With one command per page (`rowsPerBlock` = 65535, iOS only), the same ticket
printed cleanly on the same iPhone. The other platforms keep 255-row blocks;
they use SPP and print cleanly already.

## Print sequence (roll paper)

Entry point: the print activity calls `PrinterHelper.printOnce`, which runs
`BaseNormalDevice`'s print routine. Bytes, in order:

| Step | Bytes | Notes |
|---|---|---|
| Status | `10 FF 40` | One read before the job |
| Enable | `10 FF F1 03` | Lujiang family (AiYin uses `10 FF FE 01`) |
| Wake | `00` × 12 | |
| Image | `1D 76 30 00 wL wH hL hH` + rows | One command for the whole image |
| Feed | `1B 4A n` | n = 80 (`PPS1`), 112 (`DP_S1`), 144 (H models) |
| Mark last | `1B BB BB` | `PPS1`, `PPS1PRO` and Lujiang base class only, on the last copy |
| Stop | `10 FF F1 45` | Waits up to 70 s for a reply that starts with `AA` or `OK` |

- **Pacing:** commands run on one thread with a 10 ms pause before each write.
  Nothing waits for the `OK` that follows a raster command; only stop waits.
- **Rows:** packed MSB-first, 1 = black. A pixel is black when
  `(r + g + b) / 3 < 128`.
- **Device class:** chosen by Bluetooth advertised-name prefix
  (`PrinterEnum`, `startsWith`), or by a server-side model config.
  - Our model string most likely maps to `PPS1`. Its sibling `S1_EY48D` does,
    and `PPS1` turns on grayscale when the model ends in `_GY`.
  - `DP_S1` differs only in the final feed. Its `printTag` override (adds
    `1D 0C` and a paper-type command) is for gap labels, not rolls.

### Commands the job does not send

| Command | Bytes | When the SDK sends it |
|---|---|---|
| Density | `10 FF 10 00 n` (0–2) | Only when the user changes it; the printer keeps it |
| Speed | `10 FF C0 n`, read `10 FF 20 A0` | Never for this class (`supportSetSpeed = false`) |
| Heating level | `1F 70 01 n` | Other models only |
| Printer mode | `10 FF 30 27 n` | Never called |
| Paper type | `1F 80 a b` | Labels only |

## Compression (not used for the S1)

`isCompress` defaults to false, and neither `DP_S1` nor `PPS1` sets it. Other
models, or a server config with `compressWay`, use:

| Variant | Header | Fields | Payload |
|---|---|---|---|
| Way 0 / 1 | `1F 10` (`1D FE` on the "new command" set) | `wH wL hH hL`, then a 4-byte length, all big-endian | `Compress.codeESC` / `codeLihu` |
| Way 2 | `1D FE` | Little-endian | JZlib, level 6, window bits 12 |

- `codeESC` and `codeLihu` live in `libPrinterNative.so`. They disassemble to
  the same routine: statically linked zlib 1.2.3, `deflateInit2_` with level
  -1 (6), method 8, window bits 10, memLevel 8, strategy 0. The output is a
  standard zlib stream (header `28 8D`, deflate data, Adler-32 trailer).
  On failure the buffer is overwritten with `"error"`.
- Firmware support on our S1 is untested. If BLE is ever too slow again, this
  is the next lever: a receipt would shrink from about 80 KB to 5–15 KB.

## BLE transport

The SDK's own BLE client is the reference. On Android the app actually uses
classic SPP for this printer, because every `PrinterEnum` entry has
`isBleEnable = false`.

- **Characteristics:**
  - service `FF00`;
  - write on the characteristic with write-without-response (`FF02`);
  - notifications on `FF01` (replies) and `FF03` (flow control).
- **Setup:** enable `FF01` notifications, then `FF03`. Wait up to 15 s for both
  a first `01 NN` and a `02 LL HH` on `FF03`, or fail the connection.
- **Packet size:** `min(MTU − 3, LL | HH << 8)`. Android requests MTU `LL + 3`.
  For the S1 that is 200 bytes.
- **Credits:** `01 NN` adds NN credits; the count resets on disconnect.
  - Send loop: while credits are 0, wait (30 s timeout). Otherwise send
    `credits − 1` packets back to back (or all credits when fewer than 3), wait
    for the write callbacks, subtract and repeat.
  - One credit is one packet. No other delays.
  - **Verified on our S1:** writing without waiting for credits overruns the
    printer, which resets (blue light, power off).
- **SPP:** 16 KB writes with flush, no credits, no delays.

### `FF01` replies

| Reply | Meaning (SDK `UploadErrorCode`) |
|---|---|
| `FF 01` | Out of paper |
| `FF 02` | Cover open |
| `FF 03` / `FF 13` | Overheated |
| `FF 04` | Low battery |
| `OK` / `AA` | Command finished; read only while a command waits for it |

The vendor app aborts the job on any `FF xx`. s1print currently logs these and
does not abort. Once, mid-job, the printer sent `FF 01` then `FF 02`, with
paper in and the cover closed. That happened with 255-row blocks; it was not
seen again.

## Third-party drivers disagree

[minixprint](https://github.com/SwapnanilDhol/minixprint) and
[thermal-pocket-printer-basic](https://github.com/ChiaraCannolee/thermal-pocket-printer-basic)
read `FF03 01 xx` as a status byte and pace writes with fixed timers. The SDK
and our device test both say these are credits.

## How to repeat this

1. Download the app's XAPK and unzip it.
2. Run `jadx --no-res -d out com.dingdang.newprint.apk`.
3. Read `com/luckprinter/sdk_new`:
   - `device/normal/` and `device/normal/base/BaseNormalDevice` for commands;
   - the BLE client classes for the transport;
   - `PrinterImageProcessor` for packing.
4. For the native compressor, extract `lib/arm64-v8a/libPrinterNative.so` from
   `config.arm64_v8a.apk`, then use `nm -D` and `llvm-objdump`. Never run it.
