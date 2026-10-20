//! Invented identities only. Existing detail paging is the independent membership oracle.
use std::collections::BTreeMap;
use std::time::Instant;

use roaring::RoaringBitmap;
use serviceradar_topology_atlas::{
    Budget, CanonicalOrdinals, Cell, DetailScope, Error, GlyphKind, ORDINAL_PORTABLE_BYTES,
    Position, Relation, World,
};

fn position(n: u32) -> Position {
    Position {
        id: format!("sr:ordinal-{n}.example.com"),
        label: format!("ordinal-{n}.example.com"),
        x: if n == 300 { 5_000_000 } else { n + 1 },
        y: if n == 300 { 5_000_000 } else { 1 },
        min_zoom: if n == 300 { 0 } else { 24 },
        parent_id: None,
        component_id: "component:SITE01".into(),
        component: Cell::new(0, 0, 0).unwrap(),
        placement_depth: 24,
    }
}

#[test]
fn clipped_links_keep_the_remote_device_identity_across_zoom_levels() {
    let mut points: Vec<_> = (0..3).map(position).collect();
    for (point, x) in points.iter_mut().zip([4_000_000, 12_000_000, 14_000_000]) {
        point.x = x;
        point.y = 4_000_000;
        point.min_zoom = 0;
    }
    for targets in [vec![1], vec![1, 1], vec![1, 2], vec![1, 2, 1]] {
        let relations = targets
            .iter()
            .enumerate()
            .map(|(n, target)| Relation {
                id: format!("synthetic-link-{n}"),
                source: points[0].id.clone(),
                target: points[*target].id.clone(),
            })
            .collect();
        let world = World::new("synthetic-boundary".into(), 24, points.clone(), relations).unwrap();
        for mapped in [true, false] {
            let mut mapping = CanonicalOrdinals::new(&world, [9; 16]).unwrap();
            let dictionary: Vec<_> = points
                .iter()
                .enumerate()
                .filter(|(i, _)| mapped || *i != 1)
                .map(|(i, point)| (point.id.clone(), (i + 1) as u32 * 101))
                .collect();
            mapping.apply(&world, &dictionary).unwrap();
            mapping.seal(&world).unwrap();
            for zoom in [0, 1, 2] {
                let cell = Cell::new(zoom, 0, 0).unwrap();
                let tile = world.tile(cell, Budget::default()).unwrap();
                let rows = mapping
                    .tile_device_ordinals(&world, &tile.selection)
                    .unwrap();
                assert_eq!(rows.len(), tile.glyphs.len());
                assert_eq!(tile.device_count, if zoom == 0 { 3 } else { 1 });
                let mut boundaries = 0;
                for (glyph, ordinal) in tile.glyphs.iter().zip(rows) {
                    if glyph.kind == GlyphKind::Boundary {
                        boundaries += 1;
                        let expected = if mapped && targets.iter().all(|i| *i == 1) {
                            202
                        } else {
                            0
                        };
                        assert_eq!(ordinal, expected, "zoom {zoom}, targets {targets:?}");
                        assert_eq!(glyph.count, 0, "portals never add devices to the tile");
                    } else {
                        let expected = dictionary
                            .iter()
                            .find(|(id, _)| id == &glyph.id)
                            .map_or(0, |(_, value)| *value);
                        assert_eq!(ordinal, expected);
                    }
                }
                assert_eq!(boundaries, usize::from(zoom > 0));
            }
        }
    }
}

#[test]
fn canonical_membership_excludes_promoted_and_unmapped_geometry_without_relayout() {
    let positions: Vec<_> = (0..1025).map(position).collect();
    let world = World::new(
        "synthetic-ordinal-layout".into(),
        24,
        positions.clone(),
        vec![],
    )
    .unwrap();
    let budget = Budget {
        nodes: 9,
        edges: 72,
    };
    let tile = world.tile(Cell::new(0, 0, 0).unwrap(), budget).unwrap();
    let mut mapping = CanonicalOrdinals::new(&world, [0xFF; 16]).unwrap();
    let dictionary: BTreeMap<_, _> = positions
        .iter()
        .enumerate()
        .filter(|(n, _)| n % 7 != 0)
        .map(|(n, node)| (node.id.clone(), u32::MAX - n as u32 * 131_071))
        .collect();
    let rows: Vec<_> = dictionary
        .iter()
        .map(|(id, value)| (id.clone(), *value))
        .collect();
    for page in rows.chunks(500) {
        mapping.apply(&world, page).unwrap();
        mapping.apply(&world, page).unwrap();
    }
    mapping
        .apply(&world, &[("sr:other-world.example.com".into(), 7)])
        .unwrap();
    assert_eq!(
        mapping.device_ordinals(&world, &[]),
        Err(Error::OrdinalMappingNotReady)
    );
    let info = mapping.seal(&world).unwrap();
    let mut replay = CanonicalOrdinals::new(&world, [0xFF; 16]).unwrap();
    let reversed: Vec<_> = rows.iter().rev().cloned().collect();
    for page in reversed.chunks(500) {
        replay.apply(&world, page).unwrap();
    }
    let replayed = replay.seal(&world).unwrap();
    assert_eq!(info.assignment, replayed.assignment);
    assert_ne!(info.assignment, [0; 32]);
    let mut changed_rows = rows.clone();
    let first = changed_rows[0].1;
    changed_rows[0].1 = changed_rows[1].1;
    changed_rows[1].1 = first;
    let mut changed = CanonicalOrdinals::new(&world, [0xFF; 16]).unwrap();
    for page in changed_rows.chunks(500) {
        changed.apply(&world, page).unwrap();
    }
    let changed_info = changed.seal(&world).unwrap();
    assert_eq!(changed_info.mapped, info.mapped);
    assert_ne!(changed_info.assignment, info.assignment);
    assert_eq!(info.dictionary_epoch, [0xFF; 16]);
    assert_eq!(
        (info.mapped, info.total, info.ready),
        (dictionary.len(), 1025, true)
    );
    assert!(info.retained_bytes < 1025 * 4 + 256);
    let ids = vec![
        positions[0].id.clone(),
        positions[1].id.clone(),
        "sr:missing.example.com".into(),
    ];
    assert_eq!(
        mapping.device_ordinals(&world, &ids).unwrap(),
        vec![0, dictionary[&positions[1].id], 0]
    );
    assert_eq!(mapping.apply(&world, &[]), Err(Error::OrdinalMappingSealed));
    let mut union = RoaringBitmap::new();
    let mut aggregates = 0;
    for glyph in tile
        .glyphs
        .iter()
        .filter(|g| g.kind == GlyphKind::Aggregate)
    {
        aggregates += 1;
        let aggregate = world
            .aggregate_selection(&tile.selection, &glyph.id)
            .unwrap();
        let portable = mapping
            .aggregate(&world, &aggregate, ORDINAL_PORTABLE_BYTES, 1000)
            .unwrap();
        assert_eq!(
            mapping
                .aggregate(&world, &aggregate, portable.len(), 1000)
                .unwrap(),
            portable
        );
        assert_eq!(
            mapping.aggregate(&world, &aggregate, portable.len() - 1, 1000),
            Err(Error::OrdinalBudgetExceeded)
        );
        for invalid in [0, ORDINAL_PORTABLE_BYTES + 1] {
            assert_eq!(
                mapping.aggregate(&world, &aggregate, invalid, 1000),
                Err(Error::InvalidBudget)
            );
        }
        let actual = RoaringBitmap::deserialize_from(portable.as_slice()).unwrap();
        let mut expected = RoaringBitmap::new();
        let scope = DetailScope::AggregateMembers(aggregate.clone());
        let mut cursor = None;
        loop {
            let page = world.detail(&scope, cursor.as_ref()).unwrap();
            for node in page.nodes {
                if let Some(id) = dictionary.get(&node.id) {
                    expected.insert(*id);
                }
            }
            cursor = page.next;
            if cursor.is_none() {
                break;
            }
        }
        assert_eq!(actual, expected);
        assert!(actual.is_disjoint(&union));
        union |= actual;
        assert_eq!(
            mapping.aggregate(&world, &aggregate, ORDINAL_PORTABLE_BYTES, 0),
            Err(Error::InvalidBudget)
        );
    }
    assert!(aggregates > 0);
    let promoted = dictionary[&positions[300].id];
    assert!(!union.contains(promoted));
    let mut expected: RoaringBitmap = dictionary.values().copied().collect();
    expected.remove(promoted);
    assert_eq!(union, expected);
    let after = world.tile(Cell::new(0, 0, 0).unwrap(), budget).unwrap();
    assert_eq!(
        (after.revision, after.glyphs, after.edges),
        (tile.revision, tile.glyphs, tile.edges)
    );
}

#[test]
fn seed_failures_are_atomic_and_world_generations_are_fenced() {
    let world = World::new(
        "synthetic-ordinal-layout".into(),
        24,
        (0..3).map(position).collect(),
        vec![],
    )
    .unwrap();
    let other = World::new(
        "synthetic-next-layout".into(),
        24,
        (0..3).map(position).collect(),
        vec![],
    )
    .unwrap();
    let mut mapping = CanonicalOrdinals::new(&world, [1; 16]).unwrap();
    mapping
        .apply(&world, &[(position(0).id, u32::MAX)])
        .unwrap();
    assert_eq!(
        mapping.apply(&world, &[(position(1).id, 23), (position(0).id, 24)]),
        Err(Error::InvalidOrdinal)
    );
    assert_eq!(
        mapping.apply(&world, &[(position(1).id, 23), (position(1).id, 24)]),
        Err(Error::InvalidOrdinal)
    );
    assert_eq!(
        mapping.apply(&world, &[(position(2).id, 0)]),
        Err(Error::InvalidOrdinal)
    );
    assert_eq!(
        mapping.apply(&world, &vec![(position(1).id, 23); 501]),
        Err(Error::OrdinalBudgetExceeded)
    );
    assert_eq!(mapping.info(&world).unwrap().mapped, 1);
    assert_eq!(mapping.seal(&other), Err(Error::StaleDetailRevision));
    mapping.seal(&world).unwrap();
    let other_tile = other
        .tile(Cell::new(0, 0, 0).unwrap(), Budget::default())
        .unwrap();
    assert_eq!(
        mapping.tile_device_ordinals(&world, &other_tile.selection),
        Err(Error::StaleDetailRevision)
    );
    assert_eq!(
        mapping
            .device_ordinals(&world, &[position(0).id, position(1).id])
            .unwrap(),
        vec![u32::MAX, 0]
    );
    assert_eq!(
        mapping.device_ordinals(&world, &vec![position(1).id; 8193]),
        Err(Error::OrdinalBudgetExceeded)
    );
    assert_eq!(
        mapping.device_ordinals(&other, &[]),
        Err(Error::StaleDetailRevision)
    );
    let empty = World::new("synthetic-empty-world".into(), 24, vec![], vec![]).unwrap();
    let mut empty_mapping = CanonicalOrdinals::new(&empty, [2; 16]).unwrap();
    let info = empty_mapping.seal(&empty).unwrap();
    assert_eq!((info.ready, info.mapped, info.total), (true, 0, 0));
}

#[test]
#[ignore = "declared synthetic scale target"]
fn synthetic_dense_aggregate_budget_uses_bitset_bytes_not_bits() {
    // 512 minimally dense containers fit in roughly 4 MiB, but the pinned
    // library's mislabeled bit-capacity statistic would charge over 32 MiB.
    const COUNT: u32 = 512 * 4097;
    let positions = (0..COUNT)
        .map(|n| Position {
            x: n % 500_000 + 1,
            y: n / 500_000 + 1,
            min_zoom: 24,
            ..position(n)
        })
        .collect();
    let world = World::new(
        "synthetic-dense-ordinal-budget".into(),
        24,
        positions,
        vec![],
    )
    .unwrap();
    let mut mapping = CanonicalOrdinals::new(&world, [4; 16]).unwrap();
    for start in (0..COUNT).step_by(500) {
        let rows: Vec<_> = (start..(start + 500).min(COUNT))
            .map(|n| (position(n).id, (n / 4097) * 65_536 + n % 4097 + 1))
            .collect();
        mapping.apply(&world, &rows).unwrap();
    }
    mapping.seal(&world).unwrap();
    let tile = world
        .tile(
            Cell::new(0, 0, 0).unwrap(),
            Budget {
                nodes: 9,
                edges: 72,
            },
        )
        .unwrap();
    let glyph = tile
        .glyphs
        .iter()
        .find(|glyph| glyph.kind == GlyphKind::Aggregate)
        .unwrap();
    let aggregate = world
        .aggregate_selection(&tile.selection, &glyph.id)
        .unwrap();
    assert_eq!(aggregate.member_count(), COUNT as usize);
    let portable = mapping
        .aggregate(&world, &aggregate, ORDINAL_PORTABLE_BYTES, 1000)
        .unwrap();
    let decoded = RoaringBitmap::deserialize_from(portable.as_slice()).unwrap();
    assert_eq!(decoded.statistics().n_bitset_containers, 512);
    assert_eq!(decoded.len(), u64::from(COUNT));
    assert!(decoded.contains(1) && decoded.contains(511 * 65_536 + 4097));
    assert!(!decoded.contains(4098));
    assert_eq!(
        mapping.aggregate(&world, &aggregate, portable.len() - 1, 1000),
        Err(Error::OrdinalBudgetExceeded)
    );
}

#[test]
#[ignore = "declared synthetic scale target"]
fn synthetic_aggregate_scale() {
    const COUNT: u32 = 1_100_000;
    let positions = (0..COUNT)
        .map(|n| Position {
            x: if n == 300 { 5_000_000 } else { n % 500_000 + 1 },
            y: if n == 300 { 5_000_000 } else { n / 500_000 + 1 },
            ..position(n)
        })
        .collect();
    let world = World::new("synthetic-scale-ordinals".into(), 24, positions, vec![]).unwrap();
    let cpu = std::fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
    let memory = std::fs::read_to_string("/proc/meminfo").unwrap_or_default();
    println!(
        "hardware: cpu={} ram={} build=bazel_opt readers=1",
        cpu.lines()
            .find(|line| line.starts_with("model name"))
            .unwrap_or("unknown"),
        memory
            .lines()
            .find(|line| line.starts_with("MemTotal"))
            .unwrap_or("unknown")
    );
    let tile = world
        .tile(
            Cell::new(0, 0, 0).unwrap(),
            Budget {
                nodes: 9,
                edges: 72,
            },
        )
        .unwrap();
    let glyph = tile
        .glyphs
        .iter()
        .filter(|g| g.kind == GlyphKind::Aggregate)
        .max_by_key(|g| g.count)
        .unwrap();
    let aggregate = world
        .aggregate_selection(&tile.selection, &glyph.id)
        .unwrap();
    assert_eq!(aggregate.member_count(), (COUNT - 1) as usize);
    for sparse in [false, true] {
        let mut mapping = CanonicalOrdinals::new(&world, [3; 16]).unwrap();
        for start in (0..COUNT).step_by(500) {
            let rows: Vec<_> = (start..(start + 500).min(COUNT))
                .map(|n| {
                    (
                        position(n).id,
                        if sparse { 2_147_483_648 + n * 7 } else { n + 1 },
                    )
                })
                .collect();
            mapping.apply(&world, &rows).unwrap();
        }
        let info = mapping.seal(&world).unwrap();
        let mut samples = Vec::new();
        let mut size = 0;
        for sample in 0..110 {
            let start = Instant::now();
            let portable = mapping
                .aggregate(&world, &aggregate, ORDINAL_PORTABLE_BYTES, 1000)
                .unwrap();
            if sample >= 10 {
                samples.push(start.elapsed().as_nanos());
            }
            size = portable.len();
            let members = RoaringBitmap::deserialize_from(portable.as_slice()).unwrap();
            assert_eq!(members.len(), u64::from(COUNT - 1));
            let promoted = if sparse { 2_147_483_648 + 300 * 7 } else { 301 };
            assert!(!members.contains(promoted));
        }
        samples.sort_unstable();
        println!(
            "fixture=100000_infrastructure_plus_1000000_endpoints sparse={sparse} seed=arithmetic_v1 member_count={} warmup=10 samples=100 aggregate_ns_p50_p95_p99={:?} retained_mapping_bytes={} portable_bytes={size}",
            aggregate.member_count(),
            [samples[49], samples[94], samples[98]],
            info.retained_bytes
        );
    }
}
