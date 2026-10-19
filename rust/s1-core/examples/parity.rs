//! JSON-lines adapter used only by the Swift/Rust differential test runner.
#[path = "../tests/support/mod.rs"]
mod support;
use std::io::{self, BufRead};
fn main() {
    for line in io::stdin().lock().lines() {
        let v = serde_json::from_str(&line.unwrap()).unwrap();
        println!("{}", support::run(&v));
    }
}
