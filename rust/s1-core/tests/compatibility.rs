mod support;
use s1_core::*;

#[test]
fn matches_committed_swift_reference_outputs() {
    let fixtures: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/swift.json")).unwrap();
    for case in fixtures.as_array().unwrap() {
        assert_eq!(
            support::run(&case["input"]),
            case["expected"],
            "fixture {}",
            case["case"]
        );
    }
}

#[test]
fn rejects_invalid_public_parameters_without_panicking() {
    assert!(GrayPage::new(0, 1, 203, vec![]).is_err());
    assert!(GrayPage::new(2, 1, 203, vec![0]).is_err());
    assert!(GrayPage::new(usize::MAX, 2, 203, vec![]).is_err());
    let page = GrayPage::new(1, 1, 203, vec![0]).unwrap();
    assert!(page.scaled(0).is_err());
    assert!(page.collapsing_blank_runs(0, 250).is_err());
    for options in [
        PrintOptions {
            rows_per_block: 0,
            ..Default::default()
        },
        PrintOptions {
            head_width_bytes: 0,
            ..Default::default()
        },
        PrintOptions {
            rows_per_block: 65536,
            ..Default::default()
        },
    ] {
        assert!(build_job(std::slice::from_ref(&page), &options).is_err());
    }
    assert!(Command::raster(0, &[0]).is_err());
    assert!(Command::raster(2, &[0]).is_err());
    assert!(Command::raster(1, &vec![0; 65536]).is_err());
}

#[test]
fn raster_memory_limit_is_explicit() {
    let mut bytes = b"RaS2".to_vec();
    let mut header = vec![0; 1796];
    for (offset, value) in [(372, 19999u32), (376, 199999), (388, 8)] {
        header[offset..offset + 4].copy_from_slice(&value.to_be_bytes());
    }
    bytes.extend(header);
    assert_eq!(
        decode(&bytes),
        Err(RasterError::Unsupported("page exceeds 64 Mi pixels".into()))
    );
}

#[test]
fn truncated_raster_prefixes_return_errors() {
    let fixtures: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/swift.json")).unwrap();
    for fixture in fixtures.as_array().unwrap() {
        if fixture["input"]["op"] != "decode" || fixture["expected"]["error"].is_string() {
            continue;
        }
        let bytes: Vec<_> = fixture["input"]["bytes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_u64().unwrap() as u8)
            .collect();
        // Every prefix must either decode or return a structured error, never panic.
        for end in 0..bytes.len() {
            let _ = decode(&bytes[..end]);
        }
    }
}
