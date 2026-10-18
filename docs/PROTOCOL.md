# Luck Jingle S1 — protocol notes

Everything here was verified on one printer on 18 Oct 2026, unless marked otherwise.

| Field | Value |
|---|---|
| Bluetooth name | `PPS1_XXXX` (classic), `PPS1_XXXX_BLE` (BLE) |
| Model string (`10 FF 20 F0`) | `S1_LYiN48D_GY` |
| Firmware (`10 FF 20 F1`) | `V3.0.3` |
| Serial (`10 FF 20 F2`) | `2604xxS1Axxxxxx` |
| Manufacturer | Xiamen Lujiang Technology Co., Ltd. ("LuckPrinter" SDK family) |
| Printhead | 384 dots = 48 bytes per row, 203 dpi (48 mm) |
| Transport | Classic Bluetooth SPP, RFCOMM channel 1 (SDP service "SPP slave") |

## How it was found

1. The vendor's macOS app (`Luckjingle-mac.pkg`, Flutter) does not talk to the
   printer: it renders a PDF and sends it to a system printer installed by a
   separate CUPS driver. The vendor publishes no macOS driver for the S1.
2. The S1 belongs to the same LuckPrinter SDK family that
   [fichero-printer](https://github.com/0xMH/fichero-printer) documented for the
   AiYin D11s. The query commands are the same; the print start/stop commands
   are the "Lujiang" variant listed there and were confirmed here.

## Connection

The printer accepts a baseband connection and drops it a few seconds later
unless an RFCOMM channel is opened. Opening `/dev/cu.PPS1_XXXX` worked once and
then stopped opening a channel, so s1print opens RFCOMM channel 1 directly with
IOBluetooth (`openRFCOMMChannelSync`). On macOS this needs the Bluetooth
privacy permission, and the permission is checked against the *responsible
app*, so the code must run inside an app bundle whose Info.plist has
`NSBluetoothAlwaysUsageDescription`. RFCOMM MTU reported: 240 bytes.

## Queries (verified)

| Bytes | Meaning | Example answer |
|---|---|---|
| `10 FF 20 F0` | model | `S1_LYiN48D_GY` |
| `10 FF 20 F1` | firmware | `V3.0.3` |
| `10 FF 20 F2` | serial | `2604xxS1Axxxxxx` |
| `10 FF 20 EF` | boot version | no answer on the S1 |
| `10 FF 50 F1` | battery | `00 55` → 85 % |
| `10 FF 40` | status bitmask | `00` = ready |
| `10 FF 11` | density | `00 00 00` |
| `10 FF 13` | auto power-off, minutes | `1E` = 30 |
| `10 FF 70` | all info | `PPS1_XXXX_BLE\|xx:xx:xx:xx:xx:xx\|V1.5.0\|V3.0.3\|2604xxS1Axxxxxx\|91` |

Status bits (from fichero, consistent with what the S1 returned): `01` printing,
`02` cover open, `04` out of paper, `08` low battery, `20` charging,
`10`/`40` overheated.

## Printing (verified)

```
10 FF 10 00 nn          density 0..2           → "OK"
00 × 12                 wake
10 FF F1 03             start print (Lujiang; AiYin uses 10 FF FE 01)
1D 76 30 00 30 00 yL yH GS v 0 raster, 48 bytes wide, yL/yH rows, then the bits
…                       more GS v 0 blocks (s1print sends 255 rows per block)
1B 4A nn                feed nn dots
10 FF F1 45             end print              → "OK" once the job is printed
```

Pixels are 1 bit, MSB = leftmost, 1 = black.

Two failure modes seen while developing:

- **Closing too early cuts the end of the job.** The density command also
  answers "OK". Waiting for the first "OK" and closing the channel left the last
  ~15 % of a receipt as noise. The answer to `10 FF F1 45` arrives ~2 s after the
  last byte; wait for it and keep the channel open a moment longer.
- **Pacing the data too slowly leaves white bands.** At 9 kB/s the head ran
  out of data mid-page. Sending as fast as RFCOMM flow control allows prints
  cleanly (a 58 × 164 mm receipt takes about 12 s).

## What macOS sends

As an IPP Everywhere printer, macOS sends Apple Raster (`image/urf`, header
`UNIRAST`), 8-bit gray, 203 dpi, PackBits line compression. A page shorter than
the selected media is placed at the **bottom** of the media, so receipts on a
long roll size arrive with a large white area on top: s1print trims blank rows
at both ends of roll pages and never sends more than 20 mm of consecutive blank
rows.
