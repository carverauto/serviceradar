//! The declared fixture is generated without deployment data. Both distributions
//! exercise the shipping index API, including bounded publication and fresh queries.
#[path = "../src/bitmap_index.rs"]
mod bitmap_index;
use bitmap_index::{Index, Kind, ViewRow};
use roaring::RoaringBitmap;
use std::hint::black_box;
use std::time::Instant;

mod bitmap_fixture;
use bitmap_fixture::*;

#[test]
fn synthetic_scale() {
    println!("fixture: seed=deterministic arithmetic v1, infrastructure={INFRASTRUCTURE}, endpoints={ENDPOINTS}, compact_and_sparse=true, vendor_cardinality=8, region_cardinality=10, class_cardinality=2, tag_cardinality=50, availability_skew=97/2/1, samples={SAMPLES}, warmup={WARMUP}, active_readers=1, request_pins=8, build=bazel -c opt, native_deadline_ms=1000");
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
        assert_eq!(status.pending.pending_count, 0);
        assert_eq!(status.source, b"synthetic-ready");
        println!("sparse={sparse} query_ns_p50_p95_p99={q:?} query_plus_50_facets_ns_p50_p95_p99={f:?} array_query_ns_p50_p95_p99={a:?} native_accounted_bytes={} native_peak_accounted_bytes={} process_rss={} process_high_water={} selectivity=~1.1percent",status.native_bytes,status.peak_bytes,proc_field("/proc/self/status","VmRSS"),proc_field("/proc/self/status","VmHWM"));
        assert!(q[1] < 5_000_000, "four-term p95 >=5ms: {q:?}");
        assert!(f[1] < 50_000_000, "query + facet p95 >=50ms: {f:?}");
        assert!(status.native_bytes < 64_000_000);
        println!("sparse={sparse} overlay_127_leaves_plus_full_population_aggregate_ns_p50_p95_p99={overlay:?} aggregate_input_bytes={} typed_columns_bytes=896", aggregate_bytes.len());
        let mut retained_bytes = 0;
        let mut pin_lifetimes = Vec::new();
        let mut states: Vec<_> = (0..POPULATION).map(|n| values(n).3).collect();
        let mut publish_times = Vec::new();
        let mut revision = index.status().unwrap().revision;
        for tick in 0..SAMPLES {
            let request_start = Instant::now();
            let pins: Vec<_> = (0..8)
                .map(|sample| {
                    let (query, _, _, _) = index
                        .query(
                            b"synthetic-current-authority",
                            &program(tick + sample),
                            1000,
                        )
                        .unwrap();
                    let page = query
                        .page(b"synthetic-current-authority", 0, 128, 1000)
                        .unwrap();
                    (query, page)
                })
                .collect();
            assert_eq!(index.status().unwrap().pins, 8);
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
            retained_bytes = retained_bytes.max(index.status().unwrap().native_bytes);
            for (query, page) in pins {
                assert_eq!(
                    query
                        .page(b"synthetic-current-authority", 0, 128, 1000)
                        .unwrap(),
                    page
                );
                query.close().unwrap();
            }
            pin_lifetimes.push(request_start.elapsed().as_nanos());
            assert_eq!(index.status().unwrap().pins, 0);
        }
        // Each group pins one revision only while its request is in progress;
        // current readers see all accepted updates after those requests close.
        let (current, _, _, _) = index
            .query(
                b"synthetic-current-authority",
                &[(1, String::new(), Vec::new(), 0)],
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
        assert!(current_bytes <= 64_000_000 && retained_bytes <= 64_000_000);
        println!("sparse={sparse} max_retained_8_request_pins_bytes={retained_bytes} sustained_ticks={SAMPLES} publish_1percent_population_ns_p50_p95_p99={:?} pin_lifetime_ns_p50_p95_p99={:?} post_churn_native_bytes={current_bytes}",percentiles(publish_times), percentiles(pin_lifetimes));
        index.close().unwrap();
    }
}

// Vary value diversity independently of population and expression size. The
// sparse permutation spreads the first 65,536 devices over 65,536 containers;
// using a high starting ordinal alone would still exercise dense containers.
fn diversity_ordinal(n: u32, sparse: bool) -> u32 {
    if sparse {
        n.rotate_left(16) + 1
    } else {
        n + 1
    }
}

fn diversity_row(n: u32, sparse: bool, fields: u32, values: u32, churn: bool) -> bitmap_index::Row {
    let mut attributes: Vec<_> = (0..fields)
        .map(|field| {
            (
                format!("tag:cohort{field}"),
                format!("g{:05}", (n + field * 17) % values).into(),
            )
        })
        .collect();
    let unavailable = n.is_multiple_of(11) ^ (churn && n < 1_000);
    attributes.push((
        "availability".into(),
        if unavailable {
            "unavailable"
        } else {
            "healthy"
        }
        .into(),
    ));
    (diversity_ordinal(n, sparse), true, attributes)
}

#[test]
fn synthetic_diversity() {
    const DEVICES: u32 = 100_000;
    const AUTHORITY: &[u8] = b"synthetic-diversity-authority";
    println!("diversity_fixture: population={DEVICES}, predicates=2, values_independent_of_population=true, sparse_rotation=16, seed=synthetic-arithmetic-v1, deadline_ms=1000, build=bazel-opt");
    println!(
        "hardware: cpu={}, ram={}, available_parallelism={:?}",
        proc_field("/proc/cpuinfo", "model name"),
        proc_field("/proc/meminfo", "MemTotal"),
        std::thread::available_parallelism()
    );
    let mut unavailable_cases = Vec::new();
    let mut build_limits = Vec::new();
    let mut prefix_limits = Vec::new();
    for sparse in [false, true] {
        'case: for (fields, values) in [
            (1, 512),
            (1, 1024),
            (1, 4096),
            (1, 16_384),
            (1, 65_536),
            (5, 800),
            (5, 900),
            (5, 4096),
        ] {
            let supported = (0..fields)
                .map(|field| format!("tag:cohort{field}"))
                .chain(std::iter::once("availability".into()))
                .collect();
            let index = Index::new([1; 16], [2; 16], Kind::Device, supported).unwrap();
            let started = Instant::now();
            let mut revision = 0;
            let mut batch_times = Vec::new();
            for start in (0..DEVICES).step_by(500) {
                let rows = (start..start + 500)
                    .map(|n| diversity_row(n, sparse, fields, values, false))
                    .collect();
                let batch_start = Instant::now();
                match index.publish(revision, b"synthetic-diversity", rows, true) {
                    Ok(status) => revision = status.revision,
                    Err(error @ ("native_memory_budget" | "deadline_exceeded")) => {
                        let status = index.status().unwrap();
                        assert_eq!(status.revision, revision);
                        assert_eq!(status.cardinality, u64::from(start));
                        println!("sparse={sparse} fields={fields} values_per_field={values} requested_population={DEVICES} accepted_population={start} build_limit={error} rejected_batch_ns={} seed_ms={} accounted_bytes={} peak_bytes={} rss={} hwm={}", batch_start.elapsed().as_nanos(), started.elapsed().as_millis(), status.native_bytes, status.peak_bytes, proc_field("/proc/self/status", "VmRSS"), proc_field("/proc/self/status", "VmHWM"));
                        index.close().unwrap();
                        build_limits.push((sparse, fields, values, start, error));
                        continue 'case;
                    }
                    Err(error) => panic!("unexpected publication error: {error}"),
                }
                batch_times.push(batch_start.elapsed().as_nanos());
            }
            let seeded = index.status().unwrap();
            assert_eq!(seeded.cardinality, u64::from(DEVICES));
            println!("sparse={sparse} fields={fields} values_per_field={values} total_groups={} seed_ms={} batch_500_ns={:?} accounted_bytes={} peak_bytes={} rss={} hwm={} unavailable={:?}", fields * values + 2, started.elapsed().as_millis(), percentiles(batch_times), seeded.native_bytes, seeded.peak_bytes, proc_field("/proc/self/status", "VmRSS"), proc_field("/proc/self/status", "VmHWM"), seeded.unavailable);
            if !seeded.unavailable.is_empty() {
                // Record all distributions before failing, so the baseline
                // distinguishes group-cap rejection from population pressure.
                for field in ["tag:cohort0", "availability"] {
                    let value = if field == "availability" {
                        "unavailable"
                    } else {
                        "g00000"
                    };
                    match index.query(AUTHORITY, &[(0, field.into(), value.as_bytes().to_vec(), 0)], 1000) {
                        Ok((query, _, _, total)) => {
                            println!("sparse={sparse} fields={fields} values_per_field={values} field={field} total={total}");
                            query.close().unwrap();
                        }
                        Err(error) => println!("sparse={sparse} fields={fields} values_per_field={values} field={field} query_error={error}"),
                    }
                }
                unavailable_cases.push((sparse, fields, values));
                index.close().unwrap();
                continue;
            }
            let mut exact_times = Vec::new();
            let mut prefix_times = Vec::new();
            let mut prefix_limit = None;
            for sample in 0..SAMPLES + WARMUP {
                let group = sample as u32 % values;
                let program = vec![
                    (
                        0,
                        "tag:cohort0".into(),
                        format!("g{group:05}").into_bytes(),
                        0,
                    ),
                    (0, "availability".into(), b"unavailable".to_vec(), 0),
                    (1, String::new(), Vec::new(), 2),
                ];
                let expected: Vec<_> = (group..DEVICES)
                    .step_by(values as usize)
                    .filter(|n| n.is_multiple_of(11))
                    .map(|n| diversity_ordinal(n, sparse))
                    .collect();
                let start = Instant::now();
                let (query, _, _, total) = index.query(AUTHORITY, &program, 1000).unwrap();
                let elapsed = start.elapsed().as_nanos();
                assert_eq!(total, expected.len() as u64);
                let mut first_page = expected;
                first_page.sort_unstable();
                first_page.truncate(128);
                assert_eq!(query.page(AUTHORITY, 0, 128, 1000).unwrap(), first_page);
                query.close().unwrap();
                if prefix_limit.is_none() {
                    let start = Instant::now();
                    match index.query(
                        AUTHORITY,
                        &[(4, "tag:cohort0".into(), b"g00".to_vec(), 0)],
                        1000,
                    ) {
                        Ok((prefix, _, _, total)) => {
                            let elapsed = start.elapsed().as_nanos();
                            assert_eq!(
                                total,
                                (0..DEVICES).filter(|n| n % values < 1000).count() as u64
                            );
                            prefix.close().unwrap();
                            if sample >= WARMUP {
                                prefix_times.push(elapsed);
                            }
                        }
                        Err(error @ ("deadline_exceeded" | "native_memory_budget")) => {
                            println!("sparse={sparse} fields={fields} values_per_field={values} prefix_limit={error} rejected_after_ns={}", start.elapsed().as_nanos());
                            prefix_limit = Some(error);
                        }
                        Err(error) => panic!("unexpected prefix error: {error}"),
                    }
                }
                if sample >= WARMUP {
                    exact_times.push(elapsed);
                }
            }
            let program = [(0, "availability".into(), b"unavailable".to_vec(), 0)];
            let pins: Vec<_> = (0..8)
                .map(|_| index.query(AUTHORITY, &program, 1000).unwrap().0)
                .collect();
            let before: Vec<_> = (0..DEVICES)
                .filter(|n| n.is_multiple_of(11))
                .map(|n| diversity_ordinal(n, sparse))
                .collect();
            let mut first_page = before;
            first_page.sort_unstable();
            first_page.truncate(128);
            let started = Instant::now();
            for start in [0, 500] {
                let rows = (start..start + 500)
                    .map(|n| diversity_row(n, sparse, fields, values, true))
                    .collect();
                revision = index
                    .publish(revision, b"synthetic-diversity-churn", rows, true)
                    .unwrap()
                    .revision;
            }
            let churn_ns = started.elapsed().as_nanos();
            let retained = index.status().unwrap();
            for pin in pins {
                assert_eq!(pin.page(AUTHORITY, 0, 128, 1000).unwrap(), first_page);
                pin.close().unwrap();
            }
            let (current, _, _, total) = index.query(AUTHORITY, &program, 1000).unwrap();
            assert_eq!(
                total,
                (0..DEVICES)
                    .filter(|n| n.is_multiple_of(11) ^ (*n < 1000))
                    .count() as u64
            );
            current.close().unwrap();
            let prefix_ns = (!prefix_times.is_empty()).then(|| percentiles(prefix_times));
            println!("sparse={sparse} fields={fields} values_per_field={values} exact_two_predicate_ns={:?} prefix_ns={prefix_ns:?} prefix_limit={prefix_limit:?} churn_1percent_ns={churn_ns} eight_pins_retained_bytes={} after_close_bytes={} peak_bytes={}", percentiles(exact_times), retained.native_bytes, index.status().unwrap().native_bytes, retained.peak_bytes);
            if let Some(error) = prefix_limit {
                prefix_limits.push((sparse, fields, values, error));
            }
            index.close().unwrap();
        }
    }
    assert!(
        unavailable_cases.is_empty(),
        "group caps rejected bounded queries: {unavailable_cases:?}"
    );
    assert!(
        build_limits.is_empty(),
        "supported distributions failed to finish: {build_limits:?}"
    );
    assert!(
        prefix_limits.is_empty(),
        "bounded prefix queries failed: {prefix_limits:?}"
    );
}
