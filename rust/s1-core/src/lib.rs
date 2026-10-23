//! Platform-independent S1 print pipeline. No Bluetooth, UI, or OS printing APIs.
mod dither;
mod page;
mod protocol;
mod raster;

pub use dither::{BitImage, DitherMode, has_photographic_content, pack};
pub use page::GrayPage;
pub use protocol::{Command, PrintOptions, Status, build_job};
pub use raster::{RasterError, decode, decode_with_limits, is_raster};
