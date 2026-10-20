use crate::{DitherMode, GrayPage, pack};

pub struct Command;
impl Command {
    pub const GET_MODEL: [u8; 4] = [0x10, 0xff, 0x20, 0xf0];
    pub const GET_FIRMWARE: [u8; 4] = [0x10, 0xff, 0x20, 0xf1];
    pub const GET_SERIAL: [u8; 4] = [0x10, 0xff, 0x20, 0xf2];
    pub const GET_BATTERY: [u8; 4] = [0x10, 0xff, 0x50, 0xf1];
    pub const GET_STATUS: [u8; 3] = [0x10, 0xff, 0x40];
    pub const GET_SHUTDOWN_MINUTES: [u8; 3] = [0x10, 0xff, 0x13];
    pub const GET_ALL_INFO: [u8; 3] = [0x10, 0xff, 0x70];
    pub const WAKE: [u8; 12] = [0; 12];
    pub const ENABLE: [u8; 4] = [0x10, 0xff, 0xf1, 0x03];
    pub const STOP: [u8; 4] = [0x10, 0xff, 0xf1, 0x45];
    pub const FORM_FEED: [u8; 2] = [0x1d, 0x0c];
    pub fn density(level: i32) -> Vec<u8> {
        vec![0x10, 0xff, 0x10, 0, level.clamp(0, 2) as u8]
    }
    pub fn feed(dots: usize) -> Vec<u8> {
        let mut out = Vec::new();
        let mut left = dots;
        while left > 0 {
            let n = left.min(255);
            out.extend_from_slice(&[0x1b, 0x4a, n as u8]);
            left -= n;
        }
        out
    }
    pub fn raster(width_bytes: usize, rows: &[u8]) -> Result<Vec<u8>, String> {
        if width_bytes == 0
            || width_bytes > u16::MAX as usize
            || !rows.len().is_multiple_of(width_bytes)
        {
            return Err("invalid raster block width or row buffer".into());
        }
        let height = rows.len() / width_bytes;
        if height > u16::MAX as usize {
            return Err("raster block exceeds 65535 rows".into());
        }
        let mut out = vec![
            0x1d,
            0x76,
            0x30,
            0,
            width_bytes as u8,
            (width_bytes >> 8) as u8,
            height as u8,
            (height >> 8) as u8,
        ];
        out.extend_from_slice(rows);
        Ok(out)
    }
}
#[derive(Clone, Copy, Debug)]
pub struct Status(pub u8);
impl Status {
    pub fn printing(self) -> bool {
        self.0 & 1 != 0
    }
    pub fn cover_open(self) -> bool {
        self.0 & 2 != 0
    }
    pub fn out_of_paper(self) -> bool {
        self.0 & 4 != 0
    }
    pub fn low_battery(self) -> bool {
        self.0 & 8 != 0
    }
    pub fn overheated(self) -> bool {
        self.0 & 0x50 != 0
    }
    pub fn charging(self) -> bool {
        self.0 & 0x20 != 0
    }
    pub fn ready(self) -> bool {
        self.0 & 0x5e == 0
    }
    pub fn ipp_reasons(self) -> Vec<&'static str> {
        let mut out = Vec::new();
        if self.cover_open() {
            out.push("cover-open");
        }
        if self.out_of_paper() {
            out.push("media-empty");
        }
        if self.low_battery() {
            out.push("marker-supply-low");
        }
        if self.overheated() {
            out.push("other");
        }
        if out.is_empty() {
            out.push("none");
        }
        out
    }
    pub fn description(self) -> String {
        let flags = [
            (self.printing(), "printing"),
            (self.cover_open(), "cover open"),
            (self.out_of_paper(), "out of paper"),
            (self.low_battery(), "low battery"),
            (self.overheated(), "overheated"),
            (self.charging(), "charging"),
        ];
        let parts: Vec<_> = flags
            .iter()
            .filter_map(|&(on, label)| on.then_some(label))
            .collect();
        if parts.is_empty() {
            "ready".into()
        } else {
            parts.join(", ")
        }
    }
}
#[derive(Clone, Debug)]
pub struct PrintOptions {
    pub head_width_bytes: usize,
    pub density: i32,
    pub dither: DitherMode,
    pub feed_after_page: usize,
    pub label_paper: bool,
    pub trim_bottom: bool,
    pub max_blank_rows: usize,
    pub fit_content_width: bool,
    pub rows_per_block: usize,
    /// Blank runs of at least this many rows travel as an `ESC J` feed instead of
    /// raster bytes; 0 sends every row. Slow links (BLE) starve the head otherwise.
    pub blank_rows_as_feed: usize,
}
impl Default for PrintOptions {
    fn default() -> Self {
        Self {
            head_width_bytes: 48,
            density: 1,
            dither: DitherMode::Auto,
            feed_after_page: 64,
            label_paper: false,
            trim_bottom: false,
            max_blank_rows: 160,
            fit_content_width: false,
            rows_per_block: 255,
            blank_rows_as_feed: 0,
        }
    }
}
/// One write unit for a block: ink rows as raster segments, long blank runs as feeds.
fn raster_with_feeds(width_bytes: usize, rows: &[u8], min_run: usize) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    let lines: Vec<&[u8]> = rows.chunks(width_bytes).collect();
    let mut start = 0;
    let mut i = 0;
    while i < lines.len() {
        if lines[i].iter().all(|&b| b == 0) {
            let mut end = i;
            while end < lines.len() && lines[end].iter().all(|&b| b == 0) {
                end += 1;
            }
            if end - i >= min_run {
                if start < i {
                    out.extend(Command::raster(
                        width_bytes,
                        &rows[start * width_bytes..i * width_bytes],
                    )?);
                }
                out.extend(Command::feed(end - i));
                start = end;
            }
            i = end;
        } else {
            i += 1;
        }
    }
    if start < lines.len() {
        out.extend(Command::raster(width_bytes, &rows[start * width_bytes..])?);
    }
    Ok(out)
}
/// Each returned vector is one Swift-compatible write unit, including empty feed commands.
pub fn build_job(pages: &[GrayPage], options: &PrintOptions) -> Result<Vec<Vec<u8>>, String> {
    if options.head_width_bytes == 0
        || options.head_width_bytes > u16::MAX as usize
        || options.rows_per_block == 0
        || options.rows_per_block > u16::MAX as usize
    {
        return Err("invalid printhead width or rows per block".into());
    }
    let mut out = vec![
        Command::density(options.density),
        Command::WAKE.to_vec(),
        Command::ENABLE.to_vec(),
    ];
    let printable: Vec<_> = pages.iter().filter(|p| !p.is_blank(250)).cloned().collect();
    let crop = GrayPage::shared_ink_columns(&printable, 6);
    for (index, page) in printable.iter().enumerate() {
        let source = if options.fit_content_width {
            crop.map(|c| page.cropped(c))
                .unwrap_or_else(|| page.clone())
        } else {
            page.clone()
        };
        let mut fitted = source.fitted(options.head_width_bytes * 8)?;
        if options.trim_bottom {
            fitted = fitted.trimming_vertical(250);
        }
        if options.max_blank_rows > 0 {
            fitted = fitted.collapsing_blank_runs(options.max_blank_rows, 250)?;
        }
        let bitmap = pack(&fitted, options.dither, 150);
        for rows in bitmap
            .rows
            .chunks(options.rows_per_block * bitmap.width_bytes)
        {
            if options.blank_rows_as_feed == 0 {
                out.push(Command::raster(bitmap.width_bytes, rows)?);
            } else {
                out.push(raster_with_feeds(
                    bitmap.width_bytes,
                    rows,
                    options.blank_rows_as_feed,
                )?);
            }
        }
        if options.label_paper {
            out.push(Command::FORM_FEED.to_vec());
        } else if options.feed_after_page > 0
            && (index == printable.len() - 1 || !options.trim_bottom)
        {
            out.push(Command::feed(options.feed_after_page));
        }
    }
    out.push(Command::STOP.to_vec());
    Ok(out)
}
