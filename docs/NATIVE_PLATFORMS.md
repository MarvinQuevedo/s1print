# Android and Windows native preview

This branch adds native Android and Windows applications backed by the same
Rust processing library. The existing macOS application remains unchanged.
These are hardware-test builds, not signed production releases.

## What is implemented

| Feature | Android | Windows |
|---|---|---|
| Shared Rust image processing and S1 protocol | JNI library | C ABI / PInvoke DLL |
| Open PDF and images | Document picker, Open, Share | File picker |
| Preview actual processed raster | Yes | Yes |
| Native system print integration | Android PrintService | Loopback IPP bridge |
| Bluetooth Classic SPP | Android BluetoothSocket | Windows RFCOMM / StreamSocket |
| Printer selection and saved settings | Yes | Yes |
| Density, content fit and label feed | Yes | Yes |
| Test page and status/battery query | Yes | Yes |
| Job serialization and cancellation | Yes | Yes |
| Completion acknowledgment | Wait for final OK | Wait for final OK |
| Runs outside the main window | Foreground service for direct jobs | Tray application, optional login startup |
| Distribution | Debug-signed APK | Self-contained x64 ZIP and per-user installer |

Both transports consume the density command's OK before transmitting the print
body, clear old responses before the final stop command, and wait for the final
OK plus a settling interval. Missing acknowledgment is reported as an error;
there is no automatic retry that could duplicate a receipt.

## Download branch builds

Open the **Native platforms** workflow in GitHub Actions, select a successful
run for `feature/native-rust-platforms`, then download its artifacts:

- **S1Print-Android**: install `app-debug.apk`. The instrumentation test APK is
  for developers and is not needed to print.
- **S1Print-Windows-x64**: run `S1Print-Windows-x64-Setup.exe`, or extract the
  ZIP to a permanent folder and run `S1Print.exe`.

The Windows package includes .NET; no separate runtime installation is needed.
The installer is per-user. Adding/removing a Windows system printer requests
administrative access separately. The Windows package is unsigned. Android
builds use a debug key; builds from different CI machines can require uninstalling
an older test build before installing a new one.

## Android setup and use

Supported build baseline: Android 8/API 26 or newer, arm64-v8a and x86_64.

1. Pair the S1 in Android Bluetooth settings.
2. Open S1Print, grant Nearby devices access and select the paired S1.
3. Prepare the test page, inspect the preview and press **Print preview**.
4. Use **Open PDF or image**, or Share a document to S1Print, for direct printing.
5. For printing from Chrome and other apps, press **Enable system printing**,
   enable **S1 Bluetooth**, then select it in Android's print dialog.

The print service offers 58/80 mm rolls and 58 × 30/40/50/80 mm labels, monochrome,
406 dpi input, page selection and copies. It renders the selected PDF pages and
passes grayscale pixels to Rust. The print system is available to apps that
implement Android printing; enabling a service cannot add a print command to an
app that does not provide one.

Direct printing uses a foreground notification with a cancellation action.
System jobs can be canceled from Android's print queue. Document content is
processed on-device; the app requests no network permission.

### Build Android on macOS or Linux

Install Rust, Python 3, JDK 21+, Android SDK platform 36 and NDK 26.3.11579264.
Set `ANDROID_HOME` to your SDK; `ANDROID_NDK_HOME` can override the NDK path.

```sh
rustup target add aarch64-linux-android x86_64-linux-android
native/android/gradlew -p native/android assembleDebug assembleDebugAndroidTest lintDebug
```

Gradle calls `scripts/build-android-rust.py` to compile and package both JNI
libraries. The linker uses 16 KB ELF page alignment and AGP packages the libraries
with 16 KB ZIP alignment. SDK/NDK installations and generated `.so` files are
not committed.

APK: `native/android/app/build/outputs/apk/debug/app-debug.apk`.

To run native integration tests on an emulator, explicitly select its serial so
that a connected physical phone is not affected:

```sh
adb -s emulator-5554 install -r native/android/app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5554 install -r native/android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb -s emulator-5554 shell am instrument -w inc.imx.s1print.test/androidx.test.runner.AndroidJUnitRunner
```

The four tests exercise JNI, exact S1 raster bytes and preview pixels, PDF page
selection/rendering, invalid requests and PrintService registration. They do not
open a Bluetooth connection.

## Windows setup and use

Target hardware-test environment: Windows 11 x64 with Bluetooth Classic.

1. Pair the S1 in Windows Bluetooth settings.
2. Open S1Print and select the paired printer. An outgoing COM port is not
   required; the app opens RFCOMM directly.
3. Prepare and print a test page, or open a PDF/image and print its preview.
4. Press **Add system printer**. Approve Windows printer setup when prompted.
5. Print from Word, Edge or Chrome using **S1 Bluetooth** and the 58 mm roll size.

Keep S1Print running. Closing its window hides it in the system tray; **Exit**
stops the IPP bridge. **Open at login** is optional. Use **Remove system printer**
before uninstalling if you added the queue. The printer registration belongs to
the Windows print system and is not automatically removed by the per-user installer.

Settings and bounded diagnostic logs live in `%LOCALAPPDATA%\S1Print`. Logs contain
job names, status and errors, not document pixels. The app binds its HTTP/IPP
server only to loopback (`127.0.0.1` and `::1`), on port 8631. No LAN sharing is
implemented in this preview. Jobs are held in memory while the app is running;
exiting interrupts outstanding jobs rather than replaying them on restart.

The bridge accepts PWG and URF raster, advertises media collections and 406 dpi,
and implements Get-Printer-Attributes, Validate-Job, Print-Job, Create-Job,
Send-Document, Get-Jobs, Get-Job-Attributes and Cancel-Job. Unsupported PDF over
IPP is rejected; Windows is asked to rasterize it. Direct PDF opening uses the
native Windows PDF renderer.

This is an IPP bridge, not a certified IPP Everywhere/Mopria product. The full
IPP Everywhere certification suite requires additional operations and formats
beyond this preview. Actual Windows queue installation, client raster choices,
long-paper handling and any protected-print policies still require validation on
Windows. The direct-file printing path remains available independently of the
system queue.

### Build Windows on Windows

Install Rust (MSVC toolchain), Visual Studio C++ Build Tools and .NET 8 SDK.
For an installer, also install Inno Setup 6.

```powershell
./scripts/build-windows.ps1 -Installer
```

Outputs under `build/windows`: the self-contained `app` directory,
`S1Print-Windows-x64.zip`, and `S1Print-Windows-x64-Setup.exe`.
The script fails if Rust compilation, publishing or installer compilation fails.

### Native bridge and IPP tests without a printer

The protocol/queue engine targets portable .NET 8 and can be exercised on macOS,
Linux or Windows, using the host Rust library:

```sh
cargo build --manifest-path rust/Cargo.toml --release -p s1-native
dotnet run --project native/windows/S1Print.Tests
```

These tests load the actual Rust library through the C ABI, decode raster, check
media capabilities, print/cancel/abort jobs through a simulated backend, and
exercise the HTTP endpoint. The simulated backend never connects to a printer.

For external protocol tools:

```sh
dotnet run --project native/windows/S1Print.Tests -- --serve
ipptool -tv ipp://127.0.0.1:18631/ipp/print /usr/share/cups/ipptool/get-printer-attributes.test
ipptool -tv ipp://127.0.0.1:18631/ipp/print /usr/share/cups/ipptool/ipp-2.0.test
```

## Shared native API

`rust/s1-native` exports `s1_process_json` and `s1_free_string`; its C header
specifies ownership. Android exposes the same JSON contract through JNI.
Successful responses contain `ok: true` and `apiVersion: 1`; failures contain
`ok: false` and `error`. Pixels, command blocks and preview bits use base64.

Operations: `build` (grayscale pages), `raster` (PWG/URF), `commands`, and `status`.
The boundary rejects invalid dimensions, empty documents, unsupported dither
modes, oversized requests and jobs that exceed 100 pages or 32 Mi pixels before
or after scaling. Aggregate raster decoding is bounded before page allocation.
Native panics are caught at the boundary rather than unwinding into Kotlin/C#.
These are processing limits, not a guarantee of a fixed total process-memory size.

## Physical acceptance checks

These tests remain for the real printer on each platform:

- Model/battery/status query, short test page and a long real receipt.
- PDF/image printing, QR readability, small text and blank-margin trimming.
- System print queue from Chrome plus another app, page selection and copies.
- Labels only with the correct stock; verify feed behavior.
- Paper out, cover open, printer off, cancellation and disconnection.
- Confirm the last lines print before a job is marked complete.

Do not interpret byte equivalence, cross-compilation or simulated transport tests
as successful hardware printing. See `RUST_CORE.md` for the 573-case Swift/Rust
comparison and its artifacts.
