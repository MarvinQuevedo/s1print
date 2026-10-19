use crate::GrayPage;
use std::fmt;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RasterError {
    UnknownFormat,
    Truncated(String),
    Unsupported(String),
}
impl fmt::Display for RasterError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownFormat => write!(f, "not a PWG (RaS2) or Apple (UNIRAST) raster stream"),
            Self::Truncated(s) => write!(f, "raster stream ends early: {s}"),
            Self::Unsupported(s) => write!(f, "unsupported raster: {s}"),
        }
    }
}
impl std::error::Error for RasterError {}
fn truncated(s: impl Into<String>) -> RasterError {
    RasterError::Truncated(s.into())
}
fn be32(b: &[u8], i: usize) -> usize {
    u32::from_be_bytes(b[i..i + 4].try_into().unwrap()) as usize
}
pub fn is_raster(b: &[u8]) -> bool {
    b.starts_with(b"RaS2") || b.starts_with(b"UNIRAST")
}
#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Black1,
    Gray8,
    Black8,
    Rgb24,
    Rgba32,
}
impl Kind {
    fn unit(self) -> usize {
        match self {
            Self::Rgb24 => 3,
            Self::Rgba32 => 4,
            _ => 1,
        }
    }
    fn white(self) -> u8 {
        if matches!(self, Self::Black1 | Self::Black8) {
            0
        } else {
            255
        }
    }
}

pub fn decode(b: &[u8]) -> Result<Vec<GrayPage>, RasterError> {
    decode_with_limits(b, usize::MAX, usize::MAX)
}

/// Bound aggregate decoded pixels and pages before allocating each page.
pub fn decode_with_limits(
    b: &[u8],
    max_pixels: usize,
    max_pages: usize,
) -> Result<Vec<GrayPage>, RasterError> {
    let pwg = b.starts_with(b"RaS2");
    if !pwg && !b.starts_with(b"UNIRAST") {
        return Err(RasterError::UnknownFormat);
    }
    if !pwg && b.len() < 12 {
        return Err(truncated("URF file header"));
    }
    let mut pos = if pwg { 4 } else { 12 };
    let page_count = if pwg { 0 } else { be32(b, 8) };
    let header_len = if pwg { 1796 } else { 32 };
    let mut pages = Vec::new();
    let mut total_pixels = 0usize;
    while b.len().saturating_sub(pos) >= header_len && (page_count == 0 || pages.len() < page_count)
    {
        let (dpi, width, height, bpp, cs) = if pwg {
            (
                be32(b, pos + 276),
                be32(b, pos + 372),
                be32(b, pos + 376),
                be32(b, pos + 388),
                be32(b, pos + 400),
            )
        } else {
            (
                be32(b, pos + 20),
                be32(b, pos + 12),
                be32(b, pos + 16),
                b[pos] as usize,
                b[pos + 1] as usize,
            )
        };
        pos += header_len;
        let kind = match (bpp, cs, pwg) {
            (1, _, true) => Kind::Black1,
            (8, 3, true) => Kind::Black8,
            (8, _, _) => Kind::Gray8,
            (24, _, _) => Kind::Rgb24,
            (32, _, _) => Kind::Rgba32,
            _ => {
                return Err(RasterError::Unsupported(format!(
                    "{} {bpp} bpp, colour space {cs}",
                    if pwg { "PWG" } else { "URF" }
                )));
            }
        };
        total_pixels = total_pixels
            .checked_add(
                width
                    .checked_mul(height)
                    .ok_or_else(|| RasterError::Unsupported("page dimensions overflow".into()))?,
            )
            .ok_or_else(|| RasterError::Unsupported("job dimensions overflow".into()))?;
        if total_pixels > max_pixels || pages.len() >= max_pages {
            return Err(RasterError::Unsupported(
                "job exceeds raster page or pixel limit".into(),
            ));
        }
        let (page, next) = decode_bitmap(b, pos, width, height, dpi, kind)?;
        pages.push(page);
        pos = next;
    }
    if pages.is_empty() {
        return Err(truncated(if pwg {
            "no PWG page header"
        } else {
            "no URF page header"
        }));
    }
    Ok(pages)
}
fn decode_bitmap(
    b: &[u8],
    mut pos: usize,
    width: usize,
    height: usize,
    dpi: usize,
    kind: Kind,
) -> Result<(GrayPage, usize), RasterError> {
    if width == 0 || height == 0 || width >= 20000 || height >= 200000 {
        return Err(RasterError::Unsupported(format!(
            "page size {width}x{height}"
        )));
    }
    let size = width
        .checked_mul(height)
        .ok_or_else(|| RasterError::Unsupported("page dimensions overflow".into()))?;
    // A deliberate safety boundary: reject oversized inputs rather than exhausting memory.
    if size > 64 * 1024 * 1024 {
        return Err(RasterError::Unsupported("page exceeds 64 Mi pixels".into()));
    }
    let unit = kind.unit();
    let line_bytes = if kind == Kind::Black1 {
        width.div_ceil(8)
    } else {
        width * unit
    };
    let mut out = vec![255; size];
    let mut line = vec![0; line_bytes];
    let mut y = 0;
    while y < height {
        let repeats =
            *b.get(pos)
                .ok_or_else(|| truncated(format!("line {y} of {height}")))? as usize
                + 1;
        pos += 1;
        let mut filled = 0;
        while filled < line_bytes {
            let code =
                *b.get(pos)
                    .ok_or_else(|| truncated(format!("line {y} data")))? as usize;
            pos += 1;
            if code == 128 {
                line[filled..].fill(kind.white());
                filled = line_bytes;
            } else if code < 128 {
                let value = b
                    .get(pos..pos + unit)
                    .ok_or_else(|| truncated("repeat run"))?;
                for _ in 0..code + 1 {
                    if filled + unit <= line_bytes {
                        line[filled..filled + unit].copy_from_slice(value);
                        filled += unit;
                    }
                }
                pos += unit;
            } else {
                let n = (257 - code) * unit;
                let value = b
                    .get(pos..pos + n)
                    .ok_or_else(|| truncated("literal run"))?;
                let take = n.min(line_bytes - filled);
                line[filled..filled + take].copy_from_slice(&value[..take]);
                filled += take;
                pos += n;
            }
        }
        let mut gray = vec![255; width];
        for x in 0..width {
            gray[x] = match kind {
                Kind::Black1 => {
                    if line[x >> 3] & (0x80 >> (x & 7)) != 0 {
                        0
                    } else {
                        255
                    }
                }
                Kind::Gray8 => line[x],
                Kind::Black8 => 255 - line[x],
                Kind::Rgb24 | Kind::Rgba32 => {
                    let i = x * unit;
                    ((line[i] as usize * 299
                        + line[i + 1] as usize * 587
                        + line[i + 2] as usize * 114)
                        / 1000) as u8
                }
            };
        }
        for _ in 0..repeats {
            if y < height {
                out[y * width..(y + 1) * width].copy_from_slice(&gray);
                y += 1;
            }
        }
    }
    Ok((
        GrayPage::new(width, height, if dpi > 0 { dpi } else { 203 }, out)
            .map_err(RasterError::Unsupported)?,
        pos,
    ))
}
