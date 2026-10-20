//! Versioned JSON boundary shared by Android JNI and Windows C ABI.
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use s1_core::{Command, DitherMode, GrayPage, PrintOptions, Status, build_job, decode_with_limits};
use serde::Deserialize;
use serde_json::{Value, json};
use std::ffi::{CString, c_char};

const MAX_PIXELS: usize = 32 * 1024 * 1024;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Page {
    width: usize,
    height: usize,
    #[serde(default = "dpi")]
    dpi: usize,
    pixels: String,
}
fn dpi() -> usize {
    406
}
#[derive(Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
struct Options {
    density: i32,
    dither: Option<String>,
    fit_content_width: Option<bool>,
    trim_bottom: Option<bool>,
    label_paper: bool,
}
impl Default for Options {
    fn default() -> Self {
        Self {
            density: 1,
            dither: None,
            fit_content_width: None,
            trim_bottom: None,
            label_paper: false,
        }
    }
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase", deny_unknown_fields)]
enum Request {
    Build {
        pages: Vec<Page>,
        #[serde(default)]
        options: Options,
    },
    Raster {
        data: String,
        #[serde(default)]
        options: Options,
    },
    Commands,
    Status {
        raw: u8,
    },
}
fn job(pages: Vec<GrayPage>, o: Options) -> Result<Value, String> {
    let mode = match o.dither.as_deref().unwrap_or("auto") {
        "auto" => DitherMode::Auto,
        "threshold" => DitherMode::Threshold,
        "floyd" => DitherMode::Floyd,
        "atkinson" => DitherMode::Atkinson,
        _ => return Err("unknown dithering mode".into()),
    };
    if pages.len() > 100 || pages.iter().map(|p| p.pixels().len()).sum::<usize>() > MAX_PIXELS {
        return Err("job exceeds 100 pages or 32 Mi pixels".into());
    }
    // Cropping can enlarge a narrow source dramatically; bound output before resampling.
    let printable: Vec<_> = pages.iter().filter(|p| !p.is_blank(250)).cloned().collect();
    let crop = GrayPage::shared_ink_columns(&printable, 6);
    let mut output_pixels = 0usize;
    for page in &printable {
        let source = if o.fit_content_width.unwrap_or(true) {
            crop.map(|c| page.cropped(c))
                .unwrap_or_else(|| page.clone())
        } else {
            page.clone()
        };
        let height = (source.height() as f64 * 384.0 / source.width() as f64)
            .round()
            .max(1.0) as usize;
        output_pixels = output_pixels
            .checked_add(
                height
                    .checked_mul(384)
                    .ok_or("output dimensions overflow")?,
            )
            .ok_or("output dimensions overflow")?;
        if output_pixels > MAX_PIXELS {
            return Err("processed job exceeds 32 Mi pixels".into());
        }
    }
    let chunks = build_job(
        &pages,
        &PrintOptions {
            density: o.density,
            dither: mode,
            fit_content_width: o.fit_content_width.unwrap_or(true),
            trim_bottom: o.trim_bottom.unwrap_or(!o.label_paper),
            label_paper: o.label_paper,
            ..Default::default()
        },
    )?;
    if !chunks.iter().any(|c| c.starts_with(&[0x1d, 0x76, 0x30, 0])) {
        return Err("document has no printable content".into());
    }
    let mut bits = Vec::new();
    for chunk in &chunks {
        if chunk.starts_with(&[0x1d, 0x76, 0x30, 0]) {
            bits.extend_from_slice(&chunk[8..]);
        }
    }
    Ok(
        json!({"chunks":chunks.iter().map(|c|B64.encode(c)).collect::<Vec<_>>(),
        "preview":{"width":384,"height":bits.len()/48,"rows":B64.encode(bits)},
        "sourcePages":pages.len()}),
    )
}
fn run(input: &str) -> Result<Value, String> {
    let request: Request = serde_json::from_str(input).map_err(|e| e.to_string())?;
    match request {
        Request::Build { pages, options } => {
            if pages.is_empty() || pages.len() > 100 {
                return Err("provide 1 to 100 pages".into());
            }
            let mut total = 0usize;
            let mut decoded = Vec::new();
            for p in pages {
                let size = p.width.checked_mul(p.height).ok_or("page size overflow")?;
                total = total.checked_add(size).ok_or("job size overflow")?;
                if p.width == 0
                    || p.height == 0
                    || p.height > 200000
                    || p.width > 20000
                    || total > MAX_PIXELS
                    || p.dpi > 2400
                {
                    return Err("page dimensions, resolution or job size exceed limits".into());
                }
                let bytes = B64.decode(p.pixels).map_err(|e| e.to_string())?;
                decoded.push(GrayPage::new(p.width, p.height, p.dpi, bytes)?);
            }
            job(decoded, options)
        }
        Request::Raster { data, options } => {
            let bytes = B64.decode(data).map_err(|e| e.to_string())?;
            job(
                decode_with_limits(&bytes, MAX_PIXELS, 100).map_err(|e| e.to_string())?,
                options,
            )
        }
        Request::Commands => Ok(
            json!({"model":B64.encode(Command::GET_MODEL),"battery":B64.encode(Command::GET_BATTERY),
            "status":B64.encode(Command::GET_STATUS),"stop":B64.encode(Command::STOP)}),
        ),
        Request::Status { raw } => {
            let s = Status(raw);
            Ok(
                json!({"ready":s.ready(),"printing":s.printing(),"outOfPaper":s.out_of_paper(),
                "coverOpen":s.cover_open(),"overheated":s.overheated(),"lowBattery":s.low_battery(),
                "description":s.description(),"ippReasons":s.ipp_reasons()}),
            )
        }
    }
}
pub fn process_json(input: &str) -> String {
    if input.len() > 64 * 1024 * 1024 {
        return json!({"ok":false,"error":"request exceeds 64 MiB"}).to_string();
    }
    let result = std::panic::catch_unwind(|| run(input));
    match result {
        Ok(Ok(mut v)) => {
            v["ok"] = json!(true);
            v["apiVersion"] = json!(1);
            v.to_string()
        }
        Ok(Err(e)) => json!({"ok":false,"error":e}).to_string(),
        Err(_) => json!({"ok":false,"error":"native processing failed"}).to_string(),
    }
}
/// Process UTF-8 JSON. The returned NUL-terminated string must be freed with s1_free_string.
/// # Safety
/// `input` must point to `length` readable bytes for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn s1_process_json(input: *const u8, length: usize) -> *mut c_char {
    let output = if input.is_null() || length > 64 * 1024 * 1024 {
        json!({"ok":false,"error":"invalid input buffer"}).to_string()
    } else {
        // SAFETY: the C caller supplies a valid borrowed buffer per the ABI contract.
        let bytes = unsafe { std::slice::from_raw_parts(input, length) };
        match std::str::from_utf8(bytes) {
            Ok(s) => process_json(s),
            Err(_) => json!({"ok":false,"error":"input must be UTF-8"}).to_string(),
        }
    };
    CString::new(output)
        .expect("serialized JSON has no NUL bytes")
        .into_raw()
}
/// # Safety
/// `value` must be NULL or an unfreed pointer returned by s1_process_json.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn s1_free_string(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: ownership is transferred back by the caller exactly once.
        drop(unsafe { CString::from_raw(value) });
    }
}
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_inc_imx_s1print_NativeCore_processJson(
    mut env: jni::JNIEnv,
    _class: jni::objects::JClass,
    input: jni::objects::JString,
) -> jni::sys::jstring {
    let input: String = match env.get_string(&input) {
        Ok(s) => s.into(),
        Err(_) => return std::ptr::null_mut(),
    };
    match env.new_string(process_json(&input)) {
        Ok(s) => s.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bridge_matches_direct_core_and_rejects_bad_requests() {
        let pixels = vec![0u8; 384 * 3];
        let request = json!({"op":"build","pages":[{"width":384,"height":3,"pixels":B64.encode(&pixels)}],
            "options":{"density":1,"fitContentWidth":false,"trimBottom":false}});
        let result: Value = serde_json::from_str(&process_json(&request.to_string())).unwrap();
        let expected = build_job(
            &[GrayPage::new(384, 3, 406, pixels).unwrap()],
            &PrintOptions::default(),
        )
        .unwrap();
        let actual: Vec<Vec<u8>> = result["chunks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| B64.decode(c.as_str().unwrap()).unwrap())
            .collect();
        assert_eq!(actual, expected);
        assert_eq!(result["preview"]["height"], 3);
        assert_eq!(result["apiVersion"], 1);
        for s in [
            "{}",
            "invalid",
            r#"{"op":"build","pages":[]}"#,
            r#"{"op":"build","pages":[{"width":0,"height":1,"pixels":""}]}"#,
        ] {
            let v: Value = serde_json::from_str(&process_json(s)).unwrap();
            assert_eq!(v["ok"], false);
        }
    }
    #[test]
    fn c_abi_allocates_and_frees_an_error_response() {
        // SAFETY: null is explicitly accepted; returned allocation is freed once.
        unsafe {
            let p = s1_process_json(std::ptr::null(), 0);
            assert!(!p.is_null());
            s1_free_string(p);
        }
    }
}

#[cfg(test)]
mod limit_tests {
    use super::*;
    #[test]
    fn default_density_and_output_allocation_limit() {
        let normal = json!({"op":"build","pages":[{"width":384,"height":1,"pixels":B64.encode(vec![0;384])}]});
        let result: Value = serde_json::from_str(&process_json(&normal.to_string())).unwrap();
        assert_eq!(
            B64.decode(result["chunks"][0].as_str().unwrap()).unwrap()[4],
            1
        );
        let narrow = json!({"op":"build","pages":[{"width":1,"height":100000,"pixels":B64.encode(vec![0;100000])}]});
        let result: Value = serde_json::from_str(&process_json(&narrow.to_string())).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["error"], "processed job exceeds 32 Mi pixels");
    }
}
