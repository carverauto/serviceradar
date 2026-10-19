//! Native admission/projection experiment, not an HTTP, channel, or browser load test.
mod bitmap_fixture;
#[path = "../src/bitmap_index.rs"]
mod bitmap_index;

use bitmap_fixture::*;
use bitmap_index::{Index, Kind, ViewRow};
use serviceradar_topology_atlas::{
    AggregateSelection, Budget, CanonicalOrdinals, Cell, GlyphKind, Position, World,
};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

const AUTHORITY: &[u8] = b"synthetic-current-authority";
const WORKERS: usize = 8;
const VIEW_BYTES: usize = 8 * 1024 * 1024;

enum Selector {
    Leaf(u32),
    Aggregate(AggregateSelection),
}
enum OwnedRow<'a> {
    Leaf(u32),
    Aggregate(Portable<'a>),
}
#[derive(Default)]
struct Meter {
    current: AtomicUsize,
    peak: AtomicUsize,
}
struct Portable<'a> {
    bytes: Vec<u8>,
    meter: &'a Meter,
}
impl<'a> Portable<'a> {
    fn new(bytes: Vec<u8>, meter: &'a Meter) -> Self {
        let current =
            meter.current.fetch_add(bytes.capacity(), Ordering::AcqRel) + bytes.capacity();
        meter.peak.fetch_max(current, Ordering::Relaxed);
        Self { bytes, meter }
    }
}
impl Drop for Portable<'_> {
    fn drop(&mut self) {
        self.meter
            .current
            .fetch_sub(self.bytes.capacity(), Ordering::AcqRel);
    }
}
struct ExportSlot<'a>(&'a AtomicUsize);
impl<'a> ExportSlot<'a> {
    fn take(slots: &'a AtomicUsize) -> Result<Self, &'static str> {
        slots
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                (n < 2).then_some(n + 1)
            })
            .map_err(|_| "atlas_busy")?;
        Ok(Self(slots))
    }
}
impl Drop for ExportSlot<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

fn remaining(end: Instant) -> Result<u64, &'static str> {
    let ms = end.saturating_duration_since(Instant::now()).as_millis() as u64;
    if ms == 0 {
        Err("deadline_exceeded")
    } else {
        Ok(ms.min(1000))
    }
}

// The harness models a caller retrying transient admission under one deadline.
// Retries and their 100us backoff are included in latency and reported separately.
fn retry<T>(
    end: Instant,
    rejected: &mut BTreeMap<&'static str, usize>,
    mut call: impl FnMut(u64) -> Result<T, &'static str>,
) -> Result<T, &'static str> {
    loop {
        match call(remaining(end)?) {
            Err(
                reason @ ("busy"
                | "reader_budget"
                | "pin_budget"
                | "native_memory_budget"
                | "atlas_busy"),
            ) => {
                *rejected.entry(reason).or_default() += 1;
                std::thread::sleep(Duration::from_micros(100));
            }
            result => return result,
        }
    }
}

fn uid(n: u32) -> String {
    format!("sr:view-{n}.example.com")
}
fn position(n: u32) -> Position {
    let cell = n % 64;
    let promoted = n < 128;
    Position {
        id: uid(n),
        label: "Synthetic view device".into(),
        x: (cell % 8) * 2_097_152
            + if promoted {
                1_000_000 + (n / 64) * 400_000
            } else {
                100 + (n / 64) % 10_000
            },
        y: (cell / 8) * 2_097_152
            + if promoted {
                1_000_000
            } else {
                100 + n / 640_000
            },
        min_zoom: if promoted { 0 } else { 24 },
        parent_id: None,
        component_id: "synthetic-component".into(),
        component: Cell::new(0, 0, 0).unwrap(),
        placement_depth: 24,
    }
}

struct Scene<'a> {
    world: &'a World,
    mapping: CanonicalOrdinals,
    tiles: Vec<Vec<Selector>>,
}
impl<'a> Scene<'a> {
    fn new(world: &'a World, sparse: bool) -> Self {
        let mut mapping = CanonicalOrdinals::new(world, [1; 16]).unwrap();
        for start in (0..POPULATION).step_by(500) {
            let rows = (start..(start + 500).min(POPULATION))
                .map(|n| (uid(n), ordinal(n, sparse)))
                .collect::<Vec<_>>();
            mapping.apply(world, &rows).unwrap();
        }
        mapping.seal(world).unwrap();
        let mut tiles = Vec::new();
        let mut covered = 0;
        for y in 0..8 {
            for x in 0..8 {
                let tile = world
                    .tile(
                        Cell::new(3, x, y).unwrap(),
                        Budget {
                            nodes: 9,
                            edges: 72,
                        },
                    )
                    .unwrap();
                let rows = tile
                    .glyphs
                    .iter()
                    .map(|glyph| {
                        covered += glyph.count;
                        match glyph.kind {
                            GlyphKind::Device => Selector::Leaf(
                                mapping.device_ordinals(world, &[glyph.id.clone()]).unwrap()[0],
                            ),
                            GlyphKind::Aggregate => Selector::Aggregate(
                                world
                                    .aggregate_selection(&tile.selection, &glyph.id)
                                    .unwrap(),
                            ),
                            GlyphKind::Boundary => {
                                panic!("edge-free fixture must have no boundary glyphs")
                            }
                        }
                    })
                    .collect();
                tiles.push(rows);
            }
        }
        assert_eq!(covered, u64::from(POPULATION));
        Self {
            world,
            mapping,
            tiles,
        }
    }
}

struct Measurement {
    latency: u128,
    export: u128,
    projection: u128,
    portable_bytes: usize,
    column_bytes: usize,
}

fn project(
    index: &Index,
    scene: &Scene<'_>,
    sample: usize,
    expected: u64,
    exports: &AtomicUsize,
    meter: &Meter,
    rejected: &mut BTreeMap<&'static str, usize>,
) -> Result<Measurement, &'static str> {
    let start = Instant::now();
    let end = start + Duration::from_secs(1);
    let (query, _, _, total) = retry(end, rejected, |ms| {
        index.query(AUTHORITY, &program(sample), ms)
    })?;
    assert_eq!(total, expected);
    let export_start = Instant::now();
    let mut portable_bytes = 0;
    let mut tiles = Vec::new();
    for tile in &scene.tiles {
        let mut rows = Vec::new();
        for row in tile {
            rows.push(match row {
                Selector::Leaf(id) => OwnedRow::Leaf(*id),
                Selector::Aggregate(selection) => {
                    let bytes = retry(end, rejected, |ms| {
                        let _slot = ExportSlot::take(exports)?;
                        scene
                            .mapping
                            .aggregate(scene.world, selection, VIEW_BYTES - portable_bytes, ms)
                            .map_err(|e| match e {
                                serviceradar_topology_atlas::Error::DeadlineExceeded => {
                                    "deadline_exceeded"
                                }
                                _ => "atlas_export_failed",
                            })
                    })?;
                    let bytes = Portable::new(bytes, meter);
                    portable_bytes += bytes.bytes.len();
                    if portable_bytes > VIEW_BYTES {
                        return Err("view_budget");
                    }
                    OwnedRow::Aggregate(bytes)
                }
            });
        }
        tiles.push(rows);
    }
    let export = export_start.elapsed().as_nanos();
    let projection_start = Instant::now();
    let mut matched = 0u64;
    let mut column_bytes = 0;
    for tile in &tiles {
        let rows = tile
            .iter()
            .map(|row| match row {
                OwnedRow::Leaf(id) => ViewRow::Leaf(*id),
                OwnedRow::Aggregate(bytes) => ViewRow::Aggregate(&bytes.bytes),
            })
            .collect::<Vec<_>>();
        let (mask, causal, availability, counts) = retry(end, rejected, |ms| {
            query.row_overlay(AUTHORITY, &[1; 16], &[2; 16], Kind::Device, &rows, ms)
        })?;
        for ((mask, availability), count) in mask
            .iter()
            .zip(availability.iter())
            .zip(counts.chunks_exact(4))
        {
            let count = u32::from_le_bytes(count.try_into().unwrap());
            matched += u64::from(count);
            assert_eq!(*mask, u8::from(count != 0));
            assert_eq!(*availability, if count == 0 { 2 } else { 0 });
        }
        assert!(causal.iter().all(|code| *code == 3));
        column_bytes += mask.len() + causal.len() + availability.len() + counts.len();
    }
    assert_eq!(matched, total);
    remaining(end)?;
    query.close()?;
    Ok(Measurement {
        latency: start.elapsed().as_nanos(),
        export,
        projection: projection_start.elapsed().as_nanos(),
        portable_bytes,
        column_bytes,
    })
}

#[test]
fn synthetic_native_views() {
    println!("fixture: infrastructure={INFRASTRUCTURE} endpoints={ENDPOINTS} views={SAMPLES} request_workers={WORKERS} warmup={WARMUP} tiles_per_view=64 tile_node_budget=9 harness_export_slots=2 deadline_ms=1000 transient_retry_backoff_us=100 build=bazel_opt; pure_native_not_HTTP_or_NIF_gate_test=true");
    println!(
        "hardware: cpu={} ram={} parallelism={:?}",
        proc_field("/proc/cpuinfo", "model name"),
        proc_field("/proc/meminfo", "MemTotal"),
        std::thread::available_parallelism()
    );
    let world = World::new(
        "synthetic-view-scale".into(),
        24,
        (0..POPULATION).map(position).collect(),
        vec![],
    )
    .unwrap();
    let expected: Vec<_> = (0..SAMPLES)
        .map(|sample| {
            (0..POPULATION)
                .filter(|n| {
                    let (v, r, c, s) = values(*n);
                    v == (sample % 8) as u8 && r == (sample % 10) as u8 && c != 0 && s == 0
                })
                .count() as u64
        })
        .collect();
    for sparse in [false, true] {
        let scene = Scene::new(&world, sparse);
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
        let mut revision = 0;
        for start in (0..POPULATION).step_by(500) {
            revision = index
                .publish(
                    revision,
                    b"synthetic-seed",
                    (start..(start + 500).min(POPULATION))
                        .map(|n| row(n, sparse))
                        .collect(),
                    false,
                )
                .unwrap()
                .revision;
        }
        index
            .publish(revision, b"synthetic-ready", vec![], true)
            .unwrap();
        // Keep successful pins resident to measure actual native saturation policy.
        let mut admitted = Vec::new();
        let mut burst_rejected = 0;
        for sample in 0..SAMPLES {
            match index.query(AUTHORITY, &program(sample), 1000) {
                Ok((query, _, _, _)) => admitted.push(query),
                Err("pin_budget") => burst_rejected += 1,
                Err(reason) => panic!("unexpected burst result: {reason}"),
            }
        }
        assert_eq!((admitted.len(), burst_rejected), (8, 92));
        for query in admitted {
            query.close().unwrap();
        }
        let exports = AtomicUsize::new(0);
        let meter = Meter::default();
        for sample in 0..WARMUP {
            project(
                &index,
                &scene,
                sample,
                expected[sample],
                &exports,
                &meter,
                &mut BTreeMap::new(),
            )
            .unwrap();
        }
        meter.peak.store(0, Ordering::Relaxed);
        let next = AtomicUsize::new(0);
        let started = Instant::now();
        let outcomes = std::thread::scope(|scope| {
            let handles = (0..WORKERS)
                .map(|_| {
                    scope.spawn(|| {
                        let mut results = Vec::new();
                        let mut rejected = BTreeMap::new();
                        loop {
                            let sample = next.fetch_add(1, Ordering::Relaxed);
                            if sample >= SAMPLES {
                                break;
                            }
                            results.push(project(
                                &index,
                                &scene,
                                sample,
                                expected[sample],
                                &exports,
                                &meter,
                                &mut rejected,
                            ));
                        }
                        (results, rejected)
                    })
                })
                .collect::<Vec<_>>();
            handles
                .into_iter()
                .map(|worker| worker.join().unwrap())
                .collect::<Vec<_>>()
        });
        let elapsed = started.elapsed();
        let mut results = Vec::new();
        let mut rejected = BTreeMap::new();
        let mut failures = BTreeMap::new();
        for (worker, attempts) in outcomes {
            for (reason, count) in attempts {
                *rejected.entry(reason).or_insert(0usize) += count;
            }
            for result in worker {
                match result {
                    Ok(result) => results.push(result),
                    Err(reason) => *failures.entry(reason).or_insert(0usize) += 1,
                }
            }
        }
        println!("sparse={sparse} native_pin_probe_admitted=8 native_pin_probe_rejected=92 completed={} failures={failures:?} transient_admission_retries={rejected:?} total_wave_ms={}", results.len(), elapsed.as_millis());
        assert_eq!(
            results.len(),
            SAMPLES,
            "bounded native view workload did not complete: {failures:?}"
        );
        let status = index.status().unwrap();
        assert_eq!(status.pins, 0);
        assert_eq!(status.pending.pending_count, 0);
        assert_eq!(meter.current.load(Ordering::Acquire), 0);
        println!("sparse={sparse} request_ns_p50_p95_p99={:?} export_with_admission_ns_p50_p95_p99={:?} projection_with_admission_ns_p50_p95_p99={:?} max_view_portable_bytes={} column_bytes={} peak_retained_portable_bytes={} mapping_bytes={} index_native_bytes={} index_peak_bytes={} process_rss={}; export_scratch_bound_bytes=67108864 (2x32MiB), excludes_BEAM_and_geometry_from_index_budget=true",
            percentiles(results.iter().map(|m| m.latency).collect()), percentiles(results.iter().map(|m| m.export).collect()), percentiles(results.iter().map(|m| m.projection).collect()), results.iter().map(|m| m.portable_bytes).max().unwrap(), results[0].column_bytes, meter.peak.load(Ordering::Relaxed), scene.mapping.info(&world).unwrap().retained_bytes, status.native_bytes, status.peak_bytes, proc_field("/proc/self/status", "VmRSS"));
        index.close().unwrap();
    }
}
