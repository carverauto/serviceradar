//! Criterion measurements of the normalized path, per stage, on one core.
//!
//! They live among the tests because the stages are private to the crate;
//! `#[ignore]` keeps them out of the test suites. Bazel runs them as
//! `//rust/flowgger:flowgger_normalized_bench`. Set `FLOWGGER_BENCH_SECONDS`
//! for longer, steadier samples than the default.

use super::props::copy;
use super::*;
use criterion::{BatchSize, Criterion};
use std::hint::black_box;
use std::path::{Path, PathBuf};

/// The syslog rules core seeds, in the order it applies them.
const BUNDLED_SYSLOG_RULES: [&str; 5] = [
    "passthrough",
    "coraza_waf",
    "strip_full_message",
    "syslog_severity",
    "cef_severity",
];

/// Core's bundled rule files: beside this crate under Cargo, in runfiles under Bazel.
fn bundled_rules_dir() -> PathBuf {
    const RELATIVE: &str = "elixir/serviceradar_core/priv/zen/rules";
    let manifest = std::env::var("CARGO_MANIFEST_DIR").map(|dir| Path::new(&dir).join("../.."));
    let runfiles = std::env::var("TEST_SRCDIR").map(|dir| Path::new(&dir).join("_main"));
    [manifest, runfiles]
        .into_iter()
        .flatten()
        .map(|root| root.join(RELATIVE))
        .find(|dir| dir.is_dir())
        .expect("core's bundled Zen rules are not staged for this run")
}

fn bundled_syslog_rules() -> Vec<(String, String)> {
    let dir = bundled_rules_dir();
    BUNDLED_SYSLOG_RULES
        .iter()
        .map(|name| {
            let jdm = std::fs::read_to_string(dir.join(format!("{name}.json"))).unwrap();
            ((*name).to_owned(), jdm)
        })
        .collect()
}

fn criterion() -> Criterion {
    let seconds = std::env::var("FLOWGGER_BENCH_SECONDS")
        .ok()
        .and_then(|seconds| seconds.parse().ok())
        .unwrap_or(1.0);
    let criterion = Criterion::default()
        .warm_up_time(Duration::from_secs_f64(seconds))
        .measurement_time(Duration::from_secs_f64(seconds * 2.0))
        .sample_size(30);
    // A test sandbox has no `target` directory to keep baselines in.
    match std::env::var("TEST_TMPDIR") {
        Ok(tmp) => criterion.output_directory(&Path::new(&tmp).join("criterion")),
        Err(_) => criterion,
    }
}

#[test]
#[ignore = "a measurement, run by //rust/flowgger:flowgger_normalized_bench"]
fn bench_normalized_path() {
    let config = Config::from_string(
        "[input]\nrfc3164_timezone = \"UTC\"\n[output]\npartition = \"default\"\n",
    )
    .unwrap();
    let line = "<13>1 2030-01-02T03:04:05.250Z host01.example.com app 4242 ID47 \
                [test@1 detail=\"synthetic\"] synthetic message of ordinary length";
    let mut record = AutoDecoder::new(&config).decode(line).unwrap();
    record.remote_addr = Some("192.0.2.10".to_owned());
    let record = || copy(&record);

    let json_mode = GelfEncoder::new(&config);
    let no_rules = encoder(&config, active(&[]));
    let bundled = encoder(&config, active(&bundled_syslog_rules()));
    // The bundled rules must be doing their work, or the number is of nothing.
    let (_, request) = decode(&bundled.encode(record()).unwrap());
    assert_eq!(only_record(&request).severity_text, "INFO");
    assert_eq!(attribute(only_record(&request), "full_message"), None);

    let mut criterion = criterion();
    criterion.bench_function("encode/json_mode", |bench| {
        bench.iter_batched(
            record,
            |record| partition_remote_addr(json_mode.encode(record).unwrap(), "default"),
            BatchSize::SmallInput,
        );
    });
    criterion.bench_function("encode/normalized_no_rules", |bench| {
        bench.iter_batched(
            record,
            |record| no_rules.encode(record).unwrap(),
            BatchSize::SmallInput,
        );
    });
    criterion.bench_function("encode/normalized_bundled_syslog_rules", |bench| {
        bench.iter_batched(
            record,
            |record| bundled.encode(record).unwrap(),
            BatchSize::SmallInput,
        );
    });

    let limits = Limits {
        records: 256,
        bytes: 256 * 1024,
        age: Duration::from_millis(100),
    };
    let frames: Vec<Vec<u8>> = (0..limits.records)
        .map(|_| bundled.encode(record()).unwrap())
        .collect();
    let now = Instant::now();
    criterion.bench_function("batch/assemble_256_records", |bench| {
        bench.iter(|| {
            let mut batcher = Batcher::new(limits);
            let mut closed = None;
            for frame in &frames {
                closed = batcher.push(black_box(frame), now).unwrap().or(closed);
            }
            closed.or_else(|| batcher.flush()).unwrap()
        });
    });
    criterion.final_summary();
}
