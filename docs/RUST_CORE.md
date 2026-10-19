# Rust core and Swift equivalence

Status: an additive core implementation, not a replacement for the macOS app.
The macOS app and its Bluetooth connection still use Swift. Android JNI and
Windows C ABI bindings, native applications and system-print integrations now
exist in `native/`; see [NATIVE_PLATFORMS.md](NATIVE_PLATFORMS.md). Physical printer
validation is still required.

## Architecture

`rust/s1-core` contains an OS-independent library with no runtime dependencies:

- Grayscale pages, area downsampling and bilinear enlargement.
- Shared content cropping, vertical trimming and blank-run limiting.
- Threshold, Floyd–Steinberg and Atkinson dithering, including automatic selection.
- PWG and Apple URF raster decoding.
- S1 commands, status interpretation and complete job construction.

The integration uses one Rust core with platform adapters:

| Platform | Native shell and integration | Shared processing |
|---|---|---|
| macOS | Existing Swift UI, IOBluetooth and CUPS/IPP bridge | Rust library through a future C ABI |
| Android | Kotlin UI, PrintService, PDF rendering and RFCOMM | Rust library through JNI |
| Windows | C# UI, Bluetooth and a separately validated print-system bridge | Rust library through C ABI/PInvoke |

Rust does not eliminate platform-specific Bluetooth, pairing, permissions,
PDF rendering, packaging or print-system integration. Those are separate work.
A suitable first integration would pass validated grayscale pages into Rust,
then return command blocks to the existing native transport. Preserve block
boundaries and the transport's final-OK wait; the job byte stream alone does
not prove that physical printing is complete.

## Compare one case at a time

Requires Python 3, Swift and Rust on macOS. Run from the repository root:

```sh
python3 scripts/compare-rust.py
python3 scripts/compare-rust.py --case page-gradient-floyd
python3 scripts/compare-rust.py --case job-shared-crop
python3 scripts/compare-rust.py --release --output rust/target/parity-release
```

The runner compiles `tools/swift-oracle/main.swift` together with the actual,
unmodified `Sources/S1Kit` files. It sends identical JSON inputs to Swift and
Rust, compares every output value, and exits unsuccessfully on any mismatch.
The first differing JSON path identifies the pixel, byte or metadata field.
`--no-build` reuses binaries and should only be used when sources are unchanged.

Review `rust/target/parity/report.md` or `report.json`. Each case has:

- `input.json`, `swift.json`, `rust.json`.
- For image cases: input PNG and Swift/Rust PNG pairs for each processing stage,
  plus lossless PGM/PBM files. Packed bitmap previews include byte-alignment padding.
- For jobs: `swift-job.bin` and `rust-job.bin`; JSON also preserves command block boundaries.

The deterministic suite currently has 573 cases: 186 image processing cases,
256 status values, 35 command combinations, 36 complete jobs, and 60 decoder
cases. Inputs cover gradients, thresholds, white margins, a long synthetic
receipt, seeded random pages, every dithering mode, scaling in both directions,
labels, mixed page sizes, empty jobs, raster color formats, repeated lines,
literal runs, multipage streams and truncated data. The 36 job comparisons
also verify scaling/dithering composition and command splitting.

The page operation compares each transformation independently, so an upstream
difference cannot hide a downstream one. Job cases exercise the composed pipeline.
Both debug and optimized comparisons should pass before integrating the core.

## Tests without Swift

```sh
cargo test --manifest-path rust/Cargo.toml --locked --all-targets
cargo clippy --manifest-path rust/Cargo.toml --locked --all-targets -- -D warnings
```

`tests/fixtures/swift.json` commits 16 selected reference outputs captured from
S1Kit at repository revision `f48ed28`. These tests run without Swift on Windows,
Linux and macOS. Do not regenerate expected output from Rust. Any intentional
behavior change needs a separately reviewed Swift reference update.

Additional tests cover invalid public arguments, oversized raster blocks,
the raster memory limit and truncation at every prefix of representative streams.
The GitHub Actions workflow runs native tests on all three desktop systems,
checks Android compilation targets, and runs the live Swift comparison on macOS.
A configured workflow is not evidence that its remote jobs have already passed.

## Compatibility boundaries

The compatibility target is exact pixels, DPI metadata, packed bits and command
blocks for valid, supported inputs. Floating-point operation ordering and
rounding, signed error-diffusion division, threshold comparisons and color
conversion coefficients deliberately follow Swift. Keep the cross-platform
reference tests to catch compiler/architecture differences.

Rust rejects zero dimensions, invalid block sizes, and invalid raster buffers
with errors instead of Swift precondition failures or potentially nonterminating
loops. Raster decoding additionally rejects pages above 64 Mi pixels before
allocating the page buffer. This is a deliberate difference from Swift and is
covered by a Rust-only test. It is not a total process-memory limit; multiple
pages and intermediate processing buffers also consume memory.

The decoder preserves the current Swift behavior of accepting a complete page
followed by an incomplete trailing header and clipping overlong compressed runs.
Exact agreement with Swift does not establish full PWG/URF specification
conformance. Tightening parsing should be a separately reviewed change.

Native target `cargo check` validates compilation of the library, not linking,
FFI packaging, Bluetooth access or execution on a device. Physical validation
must eventually compare the same receipt on Mac, Android and Windows, including
long receipts, battery/paper errors, disconnects and the final printer acknowledgment.

## Native renderer boundary

The strict equality checks begin with the same grayscale pixels or raster bytes.
Android uses PdfRenderer and Windows uses Windows.Data.Pdf; macOS uses
CoreGraphics. These native PDF renderers can produce different antialiasing or
color conversion for the same PDF. For strict byte comparisons across systems,
feed the same grayscale/raster fixture into Rust. Compare native PDF output
separately for layout, readability, QR scanning and physical print quality.
