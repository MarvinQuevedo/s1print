/// Row-major grayscale, 0 = black and 255 = white.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GrayPage {
    width: usize,
    height: usize,
    dpi: usize,
    pixels: Vec<u8>,
}

impl GrayPage {
    pub fn new(width: usize, height: usize, dpi: usize, pixels: Vec<u8>) -> Result<Self, String> {
        if width == 0 || height == 0 || width.checked_mul(height) != Some(pixels.len()) {
            return Err("pixel buffer does not match positive page dimensions".into());
        }
        Ok(Self {
            width,
            height,
            dpi,
            pixels,
        })
    }
    pub fn width(&self) -> usize {
        self.width
    }
    pub fn height(&self) -> usize {
        self.height
    }
    pub fn dpi(&self) -> usize {
        self.dpi
    }
    pub fn pixels(&self) -> &[u8] {
        &self.pixels
    }

    pub fn scaled(&self, new_width: usize) -> Result<Self, String> {
        if new_width == 0 {
            return Err("target width must be positive".into());
        }
        let new_height =
            ((self.height as f64 * new_width as f64 / self.width as f64).round() as usize).max(1);
        let size = new_width
            .checked_mul(new_height)
            .ok_or("scaled dimensions overflow")?;
        let mut pixels = vec![255; size];
        let sx = self.width as f64 / new_width as f64;
        let sy = self.height as f64 / new_height as f64;
        for y in 0..new_height {
            for x in 0..new_width {
                pixels[y * new_width + x] = if new_width > self.width {
                    let fy = ((y as f64 + 0.5) * sy - 0.5).max(0.0);
                    let y0 = (fy as usize).min(self.height - 1);
                    let y1 = (y0 + 1).min(self.height - 1);
                    let ty = fy - y0 as f64;
                    let fx = ((x as f64 + 0.5) * sx - 0.5).max(0.0);
                    let x0 = (fx as usize).min(self.width - 1);
                    let x1 = (x0 + 1).min(self.width - 1);
                    let tx = fx - x0 as f64;
                    let a = self.pixels[y0 * self.width + x0] as f64;
                    let b = self.pixels[y0 * self.width + x1] as f64;
                    let c = self.pixels[y1 * self.width + x0] as f64;
                    let d = self.pixels[y1 * self.width + x1] as f64;
                    let v = (a * (1.0 - tx) + b * tx) * (1.0 - ty) + (c * (1.0 - tx) + d * tx) * ty;
                    v.round().clamp(0.0, 255.0) as u8
                } else {
                    let y0 = (y as f64 * sy) as usize;
                    let y1 = (((y + 1) as f64 * sy) as usize)
                        .min(self.height)
                        .max(y0 + 1);
                    let x0 = (x as f64 * sx) as usize;
                    let x1 = (((x + 1) as f64 * sx) as usize).min(self.width).max(x0 + 1);
                    let mut sum = 0usize;
                    for yy in y0..y1 {
                        for xx in x0..x1 {
                            sum += self.pixels[yy * self.width + xx] as usize;
                        }
                    }
                    (sum / ((y1 - y0) * (x1 - x0))) as u8
                };
            }
        }
        Self::new(
            new_width,
            new_height,
            self.dpi * new_width / self.width,
            pixels,
        )
    }
    pub fn fitted(&self, width: usize) -> Result<Self, String> {
        if width == self.width {
            Ok(self.clone())
        } else {
            self.scaled(width)
        }
    }
    fn row_is_blank(&self, y: usize, threshold: u8) -> bool {
        self.pixels[y * self.width..(y + 1) * self.width]
            .iter()
            .all(|&p| p >= threshold)
    }
    pub fn is_blank(&self, threshold: u8) -> bool {
        self.pixels.iter().all(|&p| p >= threshold)
    }
    pub fn trimming_vertical(&self, threshold: u8) -> Self {
        let mut first = 0;
        while first < self.height - 1 && self.row_is_blank(first, threshold) {
            first += 1;
        }
        let mut last = self.height - 1;
        while last > first && self.row_is_blank(last, threshold) {
            last -= 1;
        }
        Self {
            width: self.width,
            height: last - first + 1,
            dpi: self.dpi,
            pixels: self.pixels[first * self.width..(last + 1) * self.width].to_vec(),
        }
    }
    pub fn collapsing_blank_runs(&self, max_rows: usize, threshold: u8) -> Result<Self, String> {
        if max_rows == 0 {
            return Err("blank-run limit must be positive".into());
        }
        let mut pixels = Vec::with_capacity(self.pixels.len());
        let mut run = 0;
        for y in 0..self.height {
            if self.row_is_blank(y, threshold) {
                run += 1;
                if run > max_rows {
                    continue;
                }
            } else {
                run = 0;
            }
            pixels.extend_from_slice(&self.pixels[y * self.width..(y + 1) * self.width]);
        }
        Self::new(self.width, pixels.len() / self.width, self.dpi, pixels)
    }
    pub fn ink_columns(&self, threshold: u8) -> Option<(isize, isize)> {
        let mut left = self.width;
        let mut right = None;
        for (i, &p) in self.pixels.iter().enumerate() {
            if p < threshold {
                let x = i % self.width;
                left = left.min(x);
                right = Some(right.map_or(x, |r: usize| r.max(x)));
            }
        }
        right.map(|r| (left as isize, r as isize))
    }
    pub fn cropped(&self, columns: (isize, isize)) -> Self {
        let x0 = columns.0.max(0);
        let x1 = columns.1.min(self.width as isize - 1);
        let w = x1 - x0 + 1;
        if w <= 0 || w >= self.width as isize {
            return self.clone();
        }
        let mut pixels = Vec::with_capacity(w as usize * self.height);
        for y in 0..self.height {
            pixels.extend_from_slice(
                &self.pixels[y * self.width + x0 as usize..y * self.width + x1 as usize + 1],
            );
        }
        Self {
            width: w as usize,
            height: self.height,
            dpi: self.dpi,
            pixels,
        }
    }
    pub fn shared_ink_columns(pages: &[Self], padding: isize) -> Option<(isize, isize)> {
        pages
            .iter()
            .filter_map(|p| p.ink_columns(250))
            .reduce(|a, b| (a.0.min(b.0), a.1.max(b.1)))
            .map(|(lo, hi)| (lo - padding, hi + padding))
    }
}
