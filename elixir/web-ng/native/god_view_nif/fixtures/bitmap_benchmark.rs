//! The declared fixture is generated without deployment data. Both distributions
//! exercise the shipping index API, including bounded publication and fresh queries.
#[path = "../src/bitmap_index.rs"]
mod bitmap_index;
use bitmap_index::{Index, Instruction, Kind, Row, ViewRow};
use roaring::RoaringBitmap;
use std::hint::black_box;
use std::time::Instant;

const INFRASTRUCTURE: u32 = 100_000;
const ENDPOINTS: u32 = 1_000_000;
const POPULATION: u32 = INFRASTRUCTURE + ENDPOINTS;
const SAMPLES: usize = 100;
const WARMUP: usize = 10;
fn ordinal(n: u32, sparse: bool) -> u32 {
    if sparse {
        2_147_483_648 + n * 7
    } else {
        n + 1
    }
}
fn values(n: u32) -> (u8, u8, u8, u8) {
    (
        (n % 8) as u8,
        ((n / 8) % 10) as u8,
        if n < INFRASTRUCTURE { 0 } else { 1 },
        if n % 100 < 97 {
            0
        } else if n % 100 < 99 {
            1
        } else {
            2
        },
    )
}
fn row(n: u32, sparse: bool) -> Row {
    let (vendor, region, class, state) = values(n);
    (
        ordinal(n, sparse),
        true,
        vec![
            ("vendor".into(), format!("vendor-{vendor}").into()),
            ("region".into(), format!("region-{region}").into()),
            ("device_class".into(), class.to_string().into()),
            (
                "availability".into(),
                ["healthy", "unavailable", "unknown"][state as usize].into(),
            ),
            ("tag:cohort".into(), format!("cohort-{}", n % 50).into()),
        ],
    )
}
fn pred(facet: &str, value: impl Into<String>) -> Instruction {
    (0, facet.into(), value.into(), 0)
}
fn program(sample: usize) -> Vec<Instruction> {
    vec![
        pred("vendor", format!("vendor-{}", sample % 8)),
        pred("region", format!("region-{}", sample % 10)),
        pred("device_class", "0"),
        (3, String::new(), String::new(), 1),
        pred("availability", "healthy"),
        (1, String::new(), String::new(), 4),
    ]
}
fn percentiles(mut samples: Vec<u128>) -> [u128; 3] {
    samples.sort_unstable();
    [
        samples[samples.len() / 2],
        samples[samples.len() * 95 / 100],
        samples[samples.len() * 99 / 100],
    ]
}
fn proc_field(path: &str, prefix: &str) -> String {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .find(|line| line.starts_with(prefix))
        .unwrap_or("unavailable")
        .to_string()
}

#[test]
fn synthetic_scale() {
    println!("fixture: seed=deterministic arithmetic v1, infrastructure={INFRASTRUCTURE}, endpoints={ENDPOINTS}, compact_and_sparse=true, vendor_cardinality=8, region_cardinality=10, class_cardinality=2, tag_cardinality=50, availability_skew=97/2/1, samples={SAMPLES}, warmup={WARMUP}, concurrent_readers=1, build=bazel -c opt, native_deadline_ms=1000");
    println!(
        "hardware: cpu={}, ram={}, available_parallelism={:?}",
        proc_field("/proc/cpuinfo", "model name"),
        proc_field("/proc/meminfo", "MemTotal"),
        std::thread::available_parallelism()
    );
    let baseline: Vec<_> = (0..POPULATION).map(values).collect();
    println!(
        "array_baseline_bytes={}",
        baseline.capacity() * std::mem::size_of::<(u8, u8, u8, u8)>()
    );
    for sparse in [false, true] {
        let index = Index::new(
            [1; 16],
            [2; 16],
            Kind::Device,
            [
                "vendor",
                "region",
                "device_class",
                "availability",
                "tag:cohort",
            ]
            .map(String::from)
            .to_vec(),
        )
        .unwrap();
        let seed = Instant::now();
        let mut revision = 0;
        for start in (0..POPULATION).step_by(500) {
            let rows = (start..(start + 500).min(POPULATION))
                .map(|n| row(n, sparse))
                .collect();
            revision = index
                .publish(revision, b"synthetic-seed", rows, false)
                .unwrap()
                .revision;
        }
        index
            .publish(revision, b"synthetic-ready", vec![], true)
            .unwrap();
        println!("sparse={sparse} seed_ms={}", seed.elapsed().as_millis());
        let facets: Vec<_> = (0..50)
            .map(|n| ("tag:cohort".to_string(), format!("cohort-{n}")))
            .collect();
        let mut query_times = Vec::new();
        let mut facet_times = Vec::new();
        let mut array_times = Vec::new();
        let mut overlay_times = Vec::new();
        let aggregate: RoaringBitmap = (0..POPULATION).map(|n| ordinal(n, sparse)).collect();
        let mut aggregate_bytes = Vec::new();
        aggregate.serialize_into(&mut aggregate_bytes).unwrap();
        let mut rows: Vec<_> = (0..127)
            .map(|n| ViewRow::Leaf(ordinal(n * 101, sparse)))
            .collect();
        rows.push(ViewRow::Aggregate(&aggregate_bytes));
        for sample in 0..SAMPLES + WARMUP {
            let program = program(sample);
            let start = Instant::now();
            let (query, _, _, total) = index
                .query(b"synthetic-current-authority", &program, 1000)
                .unwrap();
            let query_ns = start.elapsed().as_nanos();
            let counts = query
                .facets(b"synthetic-current-authority", &facets, 1000)
                .unwrap();
            let facet_ns = start.elapsed().as_nanos();
            let start = Instant::now();
            let expected = black_box(&baseline)
                .iter()
                .filter(|&&(v, r, c, s)| {
                    v == sample as u8 % 8 && r == (sample % 10) as u8 && c != 0 && s == 0
                })
                .count();
            let array_ns = start.elapsed().as_nanos();
            assert_eq!(total, expected as u64);
            assert_eq!(counts.iter().sum::<u64>(), total);
            let start = Instant::now();
            let (mask, causal, availability, counts) = query
                .row_overlay(
                    b"synthetic-current-authority",
                    &[1; 16],
                    &[2; 16],
                    Kind::Device,
                    &rows,
                    1000,
                )
                .unwrap();
            let overlay_ns = start.elapsed().as_nanos();
            assert_eq!(
                u32::from_le_bytes(counts[508..512].try_into().unwrap()),
                total as u32
            );
            assert_eq!(
                mask.len() + causal.len() + availability.len() + counts.len(),
                896
            );
            assert!(causal.iter().all(|state| *state == 3));
            for (matched, state) in mask.iter().zip(availability.iter()) {
                assert_eq!(*state, if *matched == 1 { 0 } else { 2 });
            }
            if sample >= WARMUP {
                query_times.push(query_ns);
                facet_times.push(facet_ns);
                array_times.push(array_ns);
                overlay_times.push(overlay_ns);
            }
        }
        let q = percentiles(query_times);
        let f = percentiles(facet_times);
        let a = percentiles(array_times);
        let overlay = percentiles(overlay_times);
        let status = index.status().unwrap();
        assert!(status.ready);
        assert_eq!(status.source, b"synthetic-ready");
        println!("sparse={sparse} query_ns_p50_p95_p99={q:?} query_plus_50_facets_ns_p50_p95_p99={f:?} array_query_ns_p50_p95_p99={a:?} native_accounted_bytes={} native_peak_accounted_bytes={} process_rss={} process_high_water={} selectivity=~1.1percent",status.native_bytes,status.peak_bytes,proc_field("/proc/self/status","VmRSS"),proc_field("/proc/self/status","VmHWM"));
        assert!(q[1] < 5_000_000, "four-term p95 >=5ms: {q:?}");
        assert!(f[1] < 50_000_000, "query + facet p95 >=50ms: {f:?}");
        assert!(status.native_bytes < 200_000_000);
        println!("sparse={sparse} overlay_127_leaves_plus_full_population_aggregate_ns_p50_p95_p99={overlay:?} aggregate_input_bytes={} typed_columns_bytes=896", aggregate_bytes.len());
        let pins: Vec<_> = (0..100)
            .map(|sample| {
                index
                    .query(b"synthetic-current-authority", &program(sample), 1000)
                    .unwrap()
                    .0
            })
            .collect();
        let retained_bytes = index.status().unwrap().native_bytes;
        let mut states: Vec<_> = (0..POPULATION).map(|n| values(n).3).collect();
        let mut publish_times = Vec::new();
        let mut revision = index.status().unwrap().revision;
        for tick in 0..SAMPLES {
            let started = Instant::now();
            let mut pending = Vec::with_capacity(500);
            // An odd stride selects exactly 1% of the full population.
            for n in 0..POPULATION / 100 {
                let entity = (n * 101 + tick as u32 * 7919) % POPULATION;
                let old = states[entity as usize] as usize;
                let new = (old + 1) % 3;
                states[entity as usize] = new as u8;
                let mut current = row(entity, sparse);
                current
                    .2
                    .iter_mut()
                    .find(|(key, _)| key == "availability")
                    .unwrap()
                    .1 = ["healthy", "unavailable", "unknown"][new].into();
                pending.push(current);
                if pending.len() == 500 {
                    revision = index
                        .publish(
                            revision,
                            b"synthetic-churn",
                            std::mem::take(&mut pending),
                            true,
                        )
                        .unwrap()
                        .revision;
                }
            }
            assert!(pending.is_empty());
            publish_times.push(started.elapsed().as_nanos());
        }
        // A slow reader retains its admitted revision; current readers see all
        // published updates. Complete browser frame costs are measured separately.
        let still_pinned = pins[0].page(b"synthetic-current-authority", 0, 128, 1000);
        assert!(still_pinned.is_ok() || still_pinned == Err("restart_required"));
        let (current, _, _, _) = index
            .query(
                b"synthetic-current-authority",
                &[(1, String::new(), String::new(), 0)],
                1000,
            )
            .unwrap();
        let counts = current
            .facets(
                b"synthetic-current-authority",
                &["healthy", "unavailable", "unknown"]
                    .map(|value| ("availability".into(), value.into())),
                1000,
            )
            .unwrap();
        let mut expected = [0u64; 3];
        for state in states {
            expected[state as usize] += 1;
        }
        assert_eq!(counts, expected);
        let current_bytes = index.status().unwrap().native_bytes;
        println!("sparse={sparse} retained_100_queries_bytes={retained_bytes} sustained_ticks={SAMPLES} publish_1percent_population_ns_p50_p95_p99={:?} post_churn_native_bytes={current_bytes}",percentiles(publish_times));
        drop(pins);
        index.close().unwrap();
    }
}
