# Native iOS and shared-document imports

## Scope

The iOS app supports PDF/image import, multi-file shared inboxes, native SwiftUI controls,
Rust-generated monochrome previews and BLE UART printing. The Share Extension accepts
PDF and image attachments, copies their temporary representations before provider callbacks
return, and publishes a whole batch atomically in an App Group. The share panel then
prepares a preview and provides printer discovery, Print, Cancel, and Done. Its compact
UI centers on a single status, a document/printer summary, and the primary action.
Printer selection and preview are collapsible; printer selection starts expanded only
when no default is saved. Print options are summarized read-only in the panel and
configured in the main app. Import and print errors remain visible in the main status.
By default, printing starts after the user presses Print. The extension
uses the same Rust core and acknowledged, paced BLE transport as the main app. Keep the
share panel open until completion; closing it cancels its active work. Done is disabled
while printing, and a completed job cannot be sent again from the same panel.
Providers can supply a typed PDF/image, a generic data file, or a local file URL.
The importer copies the representation within its callback, validates the copied contents
with Core Graphics/ImageIO, and normalizes the extension before publishing the batch.
Generic metadata alone cannot make an unsupported file printable. Web links are rejected
with instructions to share the downloaded file; no URL is fetched automatically.
Text-only attachments accompanying documents are ignored. Factadte's Web Share call
supplies a PDF file plus title/text, so a message provider must not reject the PDF batch.
Only document providers count toward the 20-file limit. Unsupported nontext files still
reject the entire batch. The activation dictionary uses version 2 to match supported files
when their providers also offer other representations. Text is explicitly declared in
the activation rule because browser share sheets can include a separate message item;
the importer ignores those messages and still requires at least one printable document.
The app and share panel automatically scan when opened, including when Bluetooth
becomes ready after the UI appears. Selecting a printer saves its Core Bluetooth UUID
and display name in shared App Group preferences. Discovery restores that selection
only for the matching UUID. Missing or different printers are not substituted.

The main app's **Print automatically from Share** option is off by default and requires
a saved printer. When enabled, each new share panel prints once when both the saved
printer is discovered and the prepared job is ready. The readiness order does not
matter. Repeated discovery, preview updates, failed writes, and reconnects do not
trigger a second automatic attempt. **Use manual printing** disables automation for
the current panel; manual printing and cancellation also prevent a later automatic
attempt. The main app itself continues to require an explicit Print action.

Density, content fitting, and paper mode are also stored in App Group preferences and
loaded by the share panel. Existing app-local options migrate when shared settings are
absent. Each preference uses its own key so saving options cannot overwrite the saved
printer or automatic-printing choice. Forgetting the printer also disables automation.
Shared batches remain available in the main app even if the user dismisses the panel.
The share panel caps source rendering at 4 Mi pixels to reduce extension memory pressure;
larger batches stay saved and can be prepared in the main app with its 32 Mi-pixel limit.
Document-open events can import directly into the main app. Imports received during a print
are saved for later rather than silently discarded.

Android supports ACTION_SEND, ACTION_SEND_MULTIPLE, ACTION_VIEW and ClipData URI payloads.
Incoming files are copied into the private shared inbox before decoding. Relaunching the app
recovers its latest shared batch; changing options uses the private copies rather than an
expired provider grant. The previous batch remains usable if a new import fails. Android
retains up to eight batches. iOS offers explicit deletion of saved batches.

Both implementations cap a share at 20 files and 64 MiB combined, then apply the existing
100-page / 32 Mi-pixel Rust processing limits. Neither assumes a MIME type alone proves that
an input is valid. Native PDF rendering remains platform-specific; exact cross-platform
Rust parity begins at identical grayscale pixels, as described in NATIVE_PLATFORMS.md.

PDF rendering applies explicit supersampling to the 768-pixel canvas before drawing,
then lets Rust fit the image to the 384-dot printhead. Core Graphics' page drawing
transform alone does not enlarge small pages; using it directly on the final canvas
previously rasterized receipt text too small and then enlarged missing strokes.
Crop bounds and intrinsic page rotation are respected. The monochrome preview is
assembled from the exact raster payload bytes that are sent to the printer.

## BLE scope

The iOS app scans for S1/LuckPrinter advertisements, discovers UART services FF00 (write FF02,
notify FF01) or 18F0 (write 2AF1, notify 2AF0), and negotiates the write length with Core Bluetooth.
Writes honor `canSendWriteWithoutResponse` and its readiness callback, or wait for GATT write
acknowledgments when required. Protocol replies arrive through notifications. Status is checked
before output; the density OK and final print OK are separate acknowledgments. Missing final
confirmation is an error, with no automatic resend. Keep the app in the foreground during
printing. The user has confirmed printer activation from the iPhone after acknowledged,
paced writes were enabled. Paper was unavailable, so print quality remains unverified.
The simulator cannot validate a real BLE peripheral or paper output.

### Hardware investigation (2026-10-19)

The user reports that the S1 powers off completely during iPhone print attempts,
including a repeated attempt. Screenshots show connection timeouts, but do not
identify the exact failing GATT stage or establish the cause of the power loss.
Android's successful transport is classic RFCOMM, so that result alone does not validate
the iOS BLE path. Later attempts left the printer powered on but did not print.

The app now distinguishes connection, service discovery, characteristic discovery,
and notification setup timeouts. A bounded transport metadata log is stored at
`Library/Caches/ble-diagnostics.log` in the app container. It records discovered
UUIDs, characteristic properties, write lengths, reply lengths, and failures;
it contains no document or raster payloads. No automatic retries are performed.

The first device log confirms service FF00, notify FF01/FF03, and write FF02
with both write modes available. Notifications, the status query, and density
acknowledgment succeeded. The app then began two 12,248-byte raster blocks
within the same second using unacknowledged 237-byte packets, followed by a
connection timeout. Receiver overload is a hypothesis, not a proven cause.
The transport now prefers GATT-acknowledged writes and pauses 10 ms after each
packet in either mode. After this update was installed and relaunched, the user
confirmed that printing starts. Output quality still requires paper and a physical check.

The transport is based on documented related-family UART interfaces, not an assumption that
iOS exposes arbitrary SPP/RFCOMM. Reference implementations:

- https://github.com/ChiaraCannolee/thermal-pocket-printer-basic/blob/main/PROTOCOL.md
- https://github.com/0xMH/fichero-printer/blob/main/docs/PROTOCOL.md
- https://developer.apple.com/documentation/corebluetooth

The persistent inbox deliberately avoids relying on unsupported Share Extension tricks to
foreground the containing app. App Groups allow the extension and main app to exchange data:

- https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html
- https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html
- https://developer.android.com/develop/ui/compose/sharing/receive

This adds direct/share printing on iOS; it does not advertise the S1 as an AirPrint printer.
The existing Android PrintService remains available independently of sharing.

## Local build

Requirements: macOS, Xcode 16 or later with an iOS simulator runtime, XcodeGen, Python 3,
Rust and the following targets (install once):

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
python3 scripts/build-ios-rust.py
xcodegen generate --spec native/ios/project.yml
xcodebuild -project native/ios/S1Print.xcodeproj -scheme S1Print \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath native/ios/DerivedData CODE_SIGNING_ALLOWED=NO build
```

`project.yml` is the project source; generated Xcode projects, the XCFramework and derived
build outputs are ignored. Rust is linked statically through the same C JSON ABI as Windows.
The framework contains arm64 device plus arm64/x86_64 simulator slices.

For a physical iPhone, open the generated project, select your Apple development team for
both targets, enable `group.com.factadte.s1printer` in App Groups, and sign both the app and extension.
Use an App Group and bundle identifiers owned by that team. Unsigned generic device builds
check compilation only and cannot be installed on a physical iPhone.

For local tests, select an available simulator UUID explicitly:

```sh
xcodebuild -project native/ios/S1Print.xcodeproj -scheme S1Print \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UUID' \
  -parallel-testing-enabled NO -derivedDataPath native/ios/DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test
```

Simulator tests use ad-hoc local signing so App Group entitlements are present; no Apple team
or provisioning profile is required for simulator signing. Unsigned builds compile, but cannot
resolve the real shared App Group container.

Tests cover transactional inbox imports, provider representations, mixed PDF/image rendering,
the actual Rust C ABI, preview pixels, deletion, malformed inputs, and print sequencing through
an in-memory BLE channel, including missing completion and out-of-paper. They send no bytes to
hardware. Android's `testDebugUnitTest` covers private inbox persistence, ordering, limits,
rollback and cancellation on the host JVM. Building `assembleDebugAndroidTest` compiles device
integration tests without executing them. No connected Android is needed for these checks.

## CI policy

The existing workflows no longer trigger on push. Pull requests use opened/synchronize/reopened/
ready_for_review events, but every validation job is gated on `draft == false`; draft PRs
allocate no validation runners. `workflow_dispatch` is available for explicit manual runs.
Opening a ready PR or pushing updates to one runs the relevant existing checks; ordinary branch
pushes and draft updates do not. This change does not add an automatic iOS CI job. Develop and
verify locally before making a PR ready for review.

## Recorded local verification (2026-10-19)

- Android APK and instrumentation APK compilation, lint and five host JVM inbox tests passed.
  No Android device or emulator was used.
- iOS simulator app and Share Extension compiled. Twelve simulator tests passed, including
  the actual signed App Group container and foreground import pipeline.
- The unsigned generic iPhone build passed; this is a compilation check, not a device install.
- Seven Rust workspace tests and 573/573 Swift/Rust parity comparisons passed.
- Both workflow YAML files and all PR job gates were checked locally. No Actions runs were
  started. No hardware print or BLE interoperability claim follows from these checks.
