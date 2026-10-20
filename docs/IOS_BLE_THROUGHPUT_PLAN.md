# iOS BLE: a ticket that prints to the end

20-Oct-2026. Branch `fix/ios-ble-throughput` (from `feature/native-rust-platforms`).

## Report

From the iPhone (S1Print iOS, Share Extension), a Factadte ticket PDF prints one
part, stutters, and the job is cancelled. The same PDF prints completely and
identically from Chrome on the Mac (S1Print macOS) and from Android (S1Print
Android). Both of those use classic Bluetooth (RFCOMM); iOS uses BLE UART.

## Evidence

`Library/Caches/ble-diagnostics.log` from Marvin's iPhone (main app, last job
19-Oct 23:48 UTC):

- 10 chunks: 3 command chunks, 4 × 12 248 B raster, 1 × 6 104 B, stop (3 B,
  4 B). Each 12 248 B chunk took ≈3 s: **≈3.7 kB/s**.
- Writes are acknowledged (`.withResponse`), 512-byte packets, plus a fixed
  10 ms sleep after every packet (`BluetoothPrinter.send`).
- **105 notifications of 2 bytes each** arrived on FF01 while the raster was
  sent — about one per 512-byte packet. The app ignores them and does not log
  their contents.
- After the stop command one 2-byte reply arrived, not `OK`; the app waited for
  `OK` and the printer closed the link 44 s later.
- FF03 (notify) exists and is not subscribed.
- The share extension writes its log into its own container, which cannot be
  read from the Mac; the App Group container has no log.

`docs/PAPER.md` already records the failure mode for the Mac: «Pacing at
9 kB/s let the head run dry mid-page and left white bands». iOS is well below
that. Published reverse-engineering notes for this family
(thermal-pocket-printer-basic, fichero-printer) document no BLE flow control;
they say the stop command answers `AA` **or** `OK`.

## Diagnosis

1. **Too slow**: acknowledged writes plus the 10 ms pause starve the head, so it
   prints in bursts and abandons the job.
2. **End of job missed**: only `OK` counts as completion; a printer that answers
   `0xAA` (or something on FF03) is treated as silent.
3. **Unknown back-pressure**: the per-packet 2-byte notifications are probably
   the printer's flow signal. The 19-Oct power-offs came from unacknowledged
   writes sent with no back-pressure at all (two 12 KB blocks in one second).

## Plan

### Batch 1 — see what the printer says (no behaviour change)

- Log every notification as **hex** with its characteristic UUID (these are
  printer status/flow bytes, never document or raster data; cap one line at
  32 bytes).
- Subscribe to FF03 as well as FF01 (both notify); route both to `received`
  and log which one spoke.
- Per raster chunk, log bytes, elapsed ms and kB/s; per job, total bytes,
  total time and the strategy used.
- Log `maximumWriteValueLength` for both write types after connecting.
- Write the log to the **App Group** container
  (`group.com.factadte.s1printer`, `Library/Caches/ble-diagnostics.log`) from
  both the app and the extension, with the same 64 KiB cap; keep the trace
  function in one shared place.

### Batch 2 — send fast, but only as fast as the printer accepts

A `SendStrategy` in `PrintSettings` (App Group key `bleSendStrategy`), shown in
the main app under a «Bluetooth sending (diagnostics)» picker:

| Strategy | Behaviour |
|---|---|
| `ackedPaced` | Today's behaviour (acknowledged writes + 10 ms). Kept for comparison. |
| `acked` | Acknowledged writes, no fixed pause. |
| `windowed` (**target default**) | Writes without response, gated by `canSendWriteWithoutResponse`, **and** at most `window` packets (default 4) sent beyond the last printer notification; each 2-byte notification during raster frees one slot. If no notification arrives for 2 s while the window is full, fall back to one packet per 50 ms until one does. |
| `flow` | Writes without response gated only by `canSendWriteWithoutResponse`, no pause. |

- No strategy may sleep on a fixed timer between packets except the `windowed`
  fallback and `ackedPaced`.
- Every strategy keeps today's guarantees: density `OK` before the body,
  replies cleared before the stop command, a missing final confirmation is an
  error, **no automatic resend**.
- Completion: the final wait accepts `OK` **or** a lone `0xAA` byte (either
  characteristic). Keep the 90 s ceiling.
- The `windowed` window and timings are constants in one place so the device
  results can tune them.

### Batch 3 — tests

In-memory channel tests (no hardware), in `native/ios/Tests`:

- `windowed` never has more than `window` packets un-notified in flight, and
  resumes when notifications arrive.
- The 2 s silence fallback paces at one packet per 50 ms and recovers.
- Completion accepts `OK`, `AA`, and still fails on silence.
- A notification on FF03 counts like one on FF01.
- The strategy setting round-trips through the App Group defaults and defaults
  to `windowed`.
- The hex log never contains more than 32 bytes per line.

### Batch 4 — on the phone (Marvin + the main session)

1. Build and install on «iPhone de Marvin» (team `RW9J2C59YC`).
2. Print the same Factadte ticket PDF with each strategy, from the share sheet.
3. Pull the log with
   `xcrun devicectl device copy from --domain-type appGroupDataContainer
   --domain-identifier group.com.factadte.s1printer --source
   Library/Caches/ble-diagnostics.log`.
4. Choose the default from: full ticket, no white bands, no power-off, kB/s.
   Record results and the decision in `docs/IOS.md`.

## Out of scope

The Rust raster/protocol bytes (`s1-core`), Android, Windows and macOS
transports, and the Factadte PDF itself (already identical on Mac and Android).
