//! Complete source pages drive the shipping staged publisher. Every address is
//! invented inside documentation ranges; IPv4 sharing deliberately spans devices.
mod bitmap_fixture;
#[path = "../src/bitmap_index.rs"]
mod bitmap_index;
use bitmap_fixture::*;
use bitmap_index::{Index, Instruction, Kind, Query, Row};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

fn address(n: u32, changed: bool) -> (Vec<u8>, Vec<u8>) {
    let v4 = vec![
        if changed { 198 } else { 192 },
        if changed { 51 } else { 0 },
        if changed { 100 } else { 2 },
        (n % 256) as u8,
    ];
    let mut v6 = vec![0; 16];
    v6[..4].copy_from_slice(&[0x20, 1, 0x0d, 0xb8]);
    v6[4] = u8::from(changed);
    v6[12..].copy_from_slice(&n.to_be_bytes());
    (v4, v6)
}
fn publish(
    index: &Index,
    revision: u64,
    rows: Vec<Row>,
    entities: &[(u32, bool)],
    sparse: bool,
) -> Result<u64, &'static str> {
    let stage: bitmap_index::Stage = index.begin_publish(
        revision,
        b"synthetic-addresses",
        rows,
        index.status()?.ready,
    )?;
    let mut associations = Vec::new();
    for (n, changed) in entities {
        let (v4, v6) = address(*n, *changed);
        associations.push((ordinal(*n, sparse), v4));
        associations.push((ordinal(*n, sparse), v6));
    }
    for chunk in associations.chunks(500) {
        assert!(stage.add(chunk, &[])?);
    }
    assert!(stage.add(
        &[],
        &entities
            .iter()
            .map(|(n, _)| ordinal(*n, sparse))
            .collect::<Vec<_>>()
    )?);
    let status = index.finish_publish(&stage)?;
    assert!(
        status.ip_available,
        "silent IP fallback: {:?}",
        status.ip_unavailable_reason
    );
    Ok(status.revision)
}
fn cidr(bytes: Vec<u8>, bits: u16) -> Instruction {
    (8, String::new(), bytes, bits)
}
fn close(pins: &mut Vec<Query>) {
    for pin in pins.drain(..) {
        pin.close().unwrap();
    }
}

fn concurrent_queries(index: &Index, sparse: bool) {
    let next = AtomicUsize::new(0);
    let retries = AtomicUsize::new(0);
    let times = Mutex::new(Vec::new());
    std::thread::scope(|scope| {
        for _ in 0..8 {
            scope.spawn(|| loop {
                let sample = next.fetch_add(1, Ordering::Relaxed);
                if sample >= SAMPLES {
                    break;
                }
                let expected = (0..POPULATION)
                    .filter(|n| {
                        let (v, r, c, s) = values(*n);
                        v == sample as u8 % 8 && r == (sample % 10) as u8 && c != 0 && s == 0
                    })
                    .count() as u64;
                let mut expression = program(sample);
                expression.push(cidr(
                    vec![0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                    32,
                ));
                expression.push((1, String::new(), vec![], 2));
                let start = Instant::now();
                let end = start + Duration::from_secs(1);
                loop {
                    let remaining =
                        end.saturating_duration_since(Instant::now()).as_millis() as u64;
                    assert!(
                        remaining > 0,
                        "concurrent query failed to make progress within deadline"
                    );
                    match index.query(b"authority", &expression, remaining.min(1000)) {
                        Ok((query, _, _, count)) => {
                            assert_eq!(count, expected);
                            query.close().unwrap();
                            break;
                        }
                        Err("busy" | "reader_budget" | "pin_budget" | "native_memory_budget") => {
                            retries.fetch_add(1, Ordering::Relaxed);
                            std::thread::sleep(Duration::from_micros(100));
                        }
                        Err(error) => panic!("concurrent query {sample}: {error}"),
                    }
                }
                times.lock().unwrap().push(start.elapsed().as_nanos());
            });
        }
    });
    let times = times.into_inner().unwrap();
    assert_eq!(times.len(), SAMPLES);
    println!("sparse={sparse} concurrent_workers=8 completed_queries={} retries={} latency_ns_p50_p95_p99={:?}",times.len(),retries.load(Ordering::Relaxed),percentiles(times));
}

#[test]
fn synthetic_addresses() {
    println!("fixture: devices={POPULATION}, associations={}, v4_per_device=1, v6_per_device=1, v4_shared_256_addresses=true, samples={SAMPLES}, warmup={WARMUP}, pins=8, churn_ticks=100, churn_per_tick=1percent, native_only=true, build=bazel_opt",POPULATION*2);
    println!(
        "hardware: {} {}",
        proc_field("/proc/cpuinfo", "model name"),
        proc_field("/proc/meminfo", "MemTotal")
    );
    for sparse in [true, false] {
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
        let start = Instant::now();
        let mut revision = 0;
        for first in (0..POPULATION).step_by(500) {
            let entities: Vec<_> = (first..(first + 500).min(POPULATION))
                .map(|n| (n, false))
                .collect();
            revision = publish(
                &index,
                revision,
                entities.iter().map(|(n, _)| row(*n, sparse)).collect(),
                &entities,
                sparse,
            )
            .unwrap_or_else(|error| {
                panic!("seed at {first}: {error}, status={:?}", index.status())
            });
        }
        revision = index
            .publish(revision, b"synthetic-ready", vec![], true)
            .unwrap()
            .revision;
        let seeded = index.status().unwrap();
        println!(
            "sparse={sparse} seed_ms={} seed_native_bytes={} peak_native_bytes={}",
            start.elapsed().as_millis(),
            seeded.native_bytes,
            seeded.peak_bytes
        );
        assert!(seeded.native_bytes < 125_000_000);
        let mut query_times = vec![Vec::new(); 5];
        for sample in 0..SAMPLES + WARMUP {
            let n = (sample as u32 * 7919) % POPULATION;
            let (v4, v6) = address(n, false);
            let requests = [
                (vec![cidr(vec![0; 4], 0)], POPULATION as u64),
                (
                    vec![cidr(v4, 32)],
                    ((POPULATION - 1 - n % 256) / 256 + 1) as u64,
                ),
                (vec![cidr(v6, 128)], 1),
                (
                    vec![cidr(
                        vec![0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                        32,
                    )],
                    POPULATION as u64,
                ),
                (
                    vec![(4, "tag:cohort".into(), b"cohort-1".to_vec(), 0)],
                    POPULATION as u64 * 11 / 50,
                ),
            ];
            for (kind, (program, expected)) in requests.into_iter().enumerate() {
                let started = Instant::now();
                let (query, _, _, count) = index.query(b"authority", &program, 1000).unwrap();
                assert_eq!(count, expected);
                query.close().unwrap();
                if sample >= WARMUP {
                    query_times[kind].push(started.elapsed().as_nanos());
                }
            }
        }
        for (kind, times) in query_times.into_iter().enumerate() {
            println!(
                "sparse={sparse} query_kind={kind} ns_p50_p95_p99={:?}",
                percentiles(times)
            );
        }
        concurrent_queries(&index, sparse);
        let mut states = vec![false; POPULATION as usize];
        let mut ticks = Vec::new();
        let mut retries = 0;
        let mut pinned_peak = 0;
        for tick in 0..SAMPLES {
            let started = Instant::now();
            let mut pins: Vec<_> = (0..8)
                .map(|_| {
                    index
                        .query(b"authority", &[cidr(vec![192, 0, 2, 0], 24)], 1000)
                        .unwrap()
                        .0
                })
                .collect();
            let pinned_page = pins[0].page(b"authority", 0, 128, 1000).unwrap();
            for batch in (0..POPULATION / 100).step_by(500) {
                let entities: Vec<_> = (batch..(batch + 500).min(POPULATION / 100))
                    .map(|i| {
                        let n = (i * 101 + tick as u32 * 7919) % POPULATION;
                        states[n as usize] = !states[n as usize];
                        (n, states[n as usize])
                    })
                    .collect();
                let rows: Vec<_> = entities
                    .iter()
                    .map(|(n, changed)| {
                        let mut row = row(*n, sparse);
                        row.2
                            .iter_mut()
                            .find(|(key, _)| key == "availability")
                            .unwrap()
                            .1 = if *changed {
                            "unavailable".into()
                        } else {
                            "healthy".into()
                        };
                        row
                    })
                    .collect();
                match publish(&index, revision, rows.clone(), &entities, sparse) {
                    Ok(next) => revision = next,
                    Err("native_memory_budget") => {
                        assert!(
                            !pins.is_empty(),
                            "publication cannot progress without old pins"
                        );
                        retries += 1;
                        assert_eq!(
                            pins[0].page(b"authority", 0, 128, 1000).unwrap(),
                            pinned_page
                        );
                        close(&mut pins);
                        revision = publish(&index, revision, rows, &entities, sparse).unwrap();
                    }
                    Err(error) => panic!("churn tick {tick} batch {batch}: {error}"),
                }
                pinned_peak = pinned_peak.max(index.status().unwrap().native_bytes);
            }
            // A scalar-only readiness flip keeps the fully accepted address index.
            revision = index
                .publish(revision, b"synthetic-ready", vec![], true)
                .unwrap()
                .revision;
            if let Some(pin) = pins.first() {
                assert_eq!(pin.page(b"authority", 0, 128, 1000).unwrap(), pinned_page);
            }
            close(&mut pins);
            ticks.push(started.elapsed().as_nanos());
            let (query, _, _, count) = index
                .query(b"authority", &[cidr(vec![198, 51, 100, 0], 24)], 1000)
                .unwrap();
            assert_eq!(count, states.iter().filter(|state| **state).count() as u64);
            query.close().unwrap();
        }
        let status = index.status().unwrap();
        assert_eq!(status.pins, 0);
        assert_eq!(status.pending.pending_count, 0);
        assert!(status.ip_available);
        assert!(status.native_bytes < 125_000_000);
        assert!(
            status.native_bytes < seeded.native_bytes + 8 * 1024 * 1024,
            "fixed-population churn accumulated fragmented leaves: seed={} final={}",
            seeded.native_bytes,
            status.native_bytes
        );
        assert!(status.peak_bytes <= 160_000_000);
        println!("sparse={sparse} churn_tick_ns_p50_p95_p99={:?} pin_backpressure_retries={retries} pinned_peak_bytes={pinned_peak} final_native_bytes={} peak_native_bytes={} process_high_water={}",percentiles(ticks),status.native_bytes,status.peak_bytes,proc_field("/proc/self/status","VmHWM"));
    }
}
