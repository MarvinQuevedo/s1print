use crate::GrayPage;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BitImage {
    pub width_bytes: usize,
    pub height: usize,
    pub rows: Vec<u8>,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DitherMode {
    #[default]
    Auto,
    Threshold,
    Floyd,
    Atkinson,
}

pub fn has_photographic_content(page: &GrayPage) -> bool {
    let mut mid = 0usize;
    let mut inked = 0usize;
    for &p in page.pixels() {
        if p < 245 {
            inked += 1;
            if p > 40 && p < 215 {
                mid += 1;
            }
        }
    }
    inked > 0 && mid * 100 / inked > 35
}

pub fn pack(page: &GrayPage, mode: DitherMode, threshold: i32) -> BitImage {
    let mode = if mode == DitherMode::Auto {
        if has_photographic_content(page) {
            DitherMode::Atkinson
        } else {
            DitherMode::Threshold
        }
    } else {
        mode
    };
    let w = page.width();
    let h = page.height();
    let width_bytes = w.div_ceil(8);
    let mut rows = vec![0; width_bytes * h];
    if mode == DitherMode::Threshold {
        for y in 0..h {
            for x in 0..w {
                if (page.pixels()[y * w + x] as i32) < threshold {
                    rows[y * width_bytes + (x >> 3)] |= 0x80 >> (x & 7);
                }
            }
        }
    } else {
        let mut buf: Vec<i16> = page.pixels().iter().map(|&p| p as i16).collect();
        for y in 0..h {
            for x in 0..w {
                let old = buf[y * w + x] as i32;
                let black = old < threshold;
                if black {
                    rows[y * width_bytes + (x >> 3)] |= 0x80 >> (x & 7);
                }
                let err = old - if black { 0 } else { 255 };
                let neighbors: &[(isize, usize, i32, i32)] = if mode == DitherMode::Floyd {
                    &[(1, 0, 7, 16), (-1, 1, 3, 16), (0, 1, 5, 16), (1, 1, 1, 16)]
                } else {
                    &[
                        (1, 0, 1, 8),
                        (2, 0, 1, 8),
                        (-1, 1, 1, 8),
                        (0, 1, 1, 8),
                        (1, 1, 1, 8),
                        (0, 2, 1, 8),
                    ]
                };
                for &(dx, dy, num, den) in neighbors {
                    let nx = x as isize + dx;
                    let ny = y + dy;
                    if nx >= 0 && nx < w as isize && ny < h {
                        let j = ny * w + nx as usize;
                        // Signed division truncates toward zero, matching Swift.
                        buf[j] = (buf[j] as i32 + err * num / den)
                            .clamp(i16::MIN as i32, i16::MAX as i32)
                            as i16;
                    }
                }
            }
        }
    }
    BitImage {
        width_bytes,
        height: h,
        rows,
    }
}
