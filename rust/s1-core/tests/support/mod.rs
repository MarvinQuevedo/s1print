// Shared adapter for offline golden tests and differential testing.
use s1_core::*;
use serde_json::{Value, json};
fn number(v: &Value, key: &str, default: usize) -> usize {
    v[key].as_u64().map_or(default, |n| n as usize)
}
fn bytes(v: &Value) -> Vec<u8> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_u64().unwrap() as u8)
        .collect()
}
fn page(v: &Value) -> GrayPage {
    GrayPage::new(
        number(v, "width", 0),
        number(v, "height", 0),
        number(v, "dpi", 203),
        bytes(&v["pixels"]),
    )
    .unwrap()
}
fn page_json(p: &GrayPage) -> Value {
    json!({"width":p.width(),"height":p.height(),"dpi":p.dpi(),"pixels":p.pixels()})
}
fn mode(v: &Value) -> DitherMode {
    match v.as_str().unwrap_or("auto") {
        "auto" => DitherMode::Auto,
        "threshold" => DitherMode::Threshold,
        "floyd" => DitherMode::Floyd,
        "atkinson" => DitherMode::Atkinson,
        _ => panic!("invalid mode"),
    }
}
pub fn run(v: &Value) -> Value {
    match v["op"].as_str().unwrap() {
        "page" => {
            let p = page(&v["page"]);
            let b = pack(
                &p,
                mode(&v["mode"]),
                v["threshold"].as_i64().unwrap_or(150) as i32,
            );
            let c = &v["crop"];
            json!({"scaled":page_json(&p.scaled(number(v,"targetWidth",384)).unwrap()),
                "trimmed":page_json(&p.trimming_vertical(250)),
                "collapsed":page_json(&p.collapsing_blank_runs(number(v,"maxBlankRows",160),250).unwrap()),
                "cropped":page_json(&p.cropped((c[0].as_i64().unwrap() as isize,c[1].as_i64().unwrap() as isize))),
                "inkColumns":p.ink_columns(250),"blank":p.is_blank(250),"photo":has_photographic_content(&p),
                "bitmap":{"widthBytes":b.width_bytes,"height":b.height,"rows":b.rows}})
        }
        "job" => {
            let pages: Vec<_> = v["pages"].as_array().unwrap().iter().map(page).collect();
            let o = &v["options"];
            let options = PrintOptions {
                head_width_bytes: number(o, "headWidthBytes", 48),
                density: o["density"].as_i64().unwrap_or(1) as i32,
                dither: mode(&o["dither"]),
                feed_after_page: number(o, "feedAfterPage", 64),
                label_paper: o["labelPaper"].as_bool().unwrap_or(false),
                trim_bottom: o["trimBottom"].as_bool().unwrap_or(false),
                max_blank_rows: number(o, "maxBlankRows", 160),
                fit_content_width: o["fitContentWidth"].as_bool().unwrap_or(false),
                rows_per_block: number(o, "rowsPerBlock", 255),
            };
            json!({"chunks":build_job(&pages,&options).unwrap(),"sharedInkColumns":GrayPage::shared_ink_columns(&pages,6)})
        }
        "decode" => {
            let b = bytes(&v["bytes"]);
            match decode(&b) {
                Ok(pages) => {
                    json!({"isRaster":is_raster(&b),"pages":pages.iter().map(page_json).collect::<Vec<_>>()})
                }
                Err(e) => json!({"isRaster":is_raster(&b),"error":e.to_string()}),
            }
        }
        "status" => {
            let s = Status(number(v, "raw", 0) as u8);
            json!({"printing":s.printing(),"coverOpen":s.cover_open(),"outOfPaper":s.out_of_paper(),
                "lowBattery":s.low_battery(),"overheated":s.overheated(),"charging":s.charging(),
                "ready":s.ready(),"ippReasons":s.ipp_reasons(),"description":s.description()})
        }
        "commands" => json!({"density":Command::density(v["density"].as_i64().unwrap() as i32),
            "feed":Command::feed(number(v,"dots",0)),
            "fixed":[Command::GET_MODEL.to_vec(),Command::GET_FIRMWARE.to_vec(),Command::GET_SERIAL.to_vec(),
                Command::GET_BATTERY.to_vec(),Command::GET_STATUS.to_vec(),Command::GET_SHUTDOWN_MINUTES.to_vec(),
                Command::GET_ALL_INFO.to_vec(),Command::WAKE.to_vec(),Command::ENABLE.to_vec(),Command::STOP.to_vec(),Command::FORM_FEED.to_vec()]}),
        _ => panic!("unknown operation"),
    }
}
