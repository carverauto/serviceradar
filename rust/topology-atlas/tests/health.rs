//! Invented availability and geometry only; public APIs own state/count proof.

use std::collections::HashSet;

use serviceradar_topology_atlas::{
    Budget, Cell, Error, GlyphKind, HealthCounts, HealthIndex, HealthObservation, HealthState,
    Position, Relation, TileHealth, World,
};

fn point(i: u32) -> Position {
    Position {
        id: format!("sr:health-{i:04}.example.com"),
        label: format!("health-{i:04}.example.com"),
        x: if i == 300 { 5_000_000 } else { i + 1 },
        y: if i == 300 { 5_000_000 } else { 1 },
        min_zoom: if i == 300 { 0 } else { 24 },
        parent_id: None,
        component_id: "SITE01".into(),
        component: Cell::new(0, 0, 0).unwrap(),
        placement_depth: 24,
    }
}

fn observation(i: u32, state: HealthState) -> HealthObservation {
    HealthObservation {
        device_id: point(i).id,
        state,
    }
}

fn summary(health: &TileHealth) -> HealthCounts {
    let mut total = HealthCounts::default();
    for row in &health.glyphs {
        let counts = row.counts;
        assert_eq!(
            counts.healthy + counts.unavailable + counts.unknown,
            counts.total
        );
        assert!(counts.observed <= counts.total);
        total.healthy += counts.healthy;
        total.unavailable += counts.unavailable;
        total.unknown += counts.unknown;
        total.observed += counts.observed;
        total.total += counts.total;
    }
    total
}

#[test]
fn bounded_seed_pages_conserve_counts_and_exclude_promoted_devices() {
    let nodes: Vec<_> = (0..1025).map(point).collect();
    let world = World::new("health-counts".into(), 24, nodes, vec![]).unwrap();
    let tile = world
        .tile(
            Cell::new(0, 0, 0).unwrap(),
            Budget {
                nodes: 9,
                edges: 72,
            },
        )
        .unwrap();
    let mut health = HealthIndex::new(&world, 1).unwrap();
    let initial = health.tile_health(&world, &tile.selection).unwrap();
    assert_eq!(
        summary(&initial),
        HealthCounts {
            unknown: 1025,
            total: 1025,
            ..Default::default()
        }
    );
    let expected_state = |i| {
        if i == 300 {
            HealthState::Healthy
        } else if i % 3 == 0 {
            HealthState::Unknown
        } else {
            HealthState::Unavailable
        }
    };
    let mut cursor = None;
    let mut ids = HashSet::new();
    let mut sequence = 0;
    loop {
        let page = world.device_ids_page(cursor.as_ref(), 500).unwrap();
        assert!(page.ids.len() <= 500);
        let rows: Vec<_> = page
            .ids
            .iter()
            .map(|id| {
                assert!(ids.insert(id.clone()));
                let i: u32 = id
                    .strip_prefix("sr:health-")
                    .unwrap()
                    .split('.')
                    .next()
                    .unwrap()
                    .parse()
                    .unwrap();
                observation(i, expected_state(i))
            })
            .collect();
        sequence += 1;
        assert_eq!(
            health.apply(&world, sequence, &rows).unwrap().applied,
            rows.len()
        );
        cursor = page.next;
        if cursor.is_none() {
            break;
        }
    }
    assert_eq!(ids.len(), 1025);
    let counts = health.tile_health(&world, &tile.selection).unwrap();
    assert_eq!(counts.epoch, 1);
    assert_eq!(counts.observation_sequence, 3);
    assert_eq!(counts.revision, 3);
    let info = health.info(&world).unwrap();
    assert_eq!(
        (info.epoch, info.revision, info.observation_sequence),
        (1, 3, 3)
    );
    assert_eq!((info.observed, info.total), (1025, 1025));
    assert!(info.retained_bytes > 1025 * 21 && info.retained_bytes < 1025 * 22);
    assert_eq!(
        summary(&counts),
        HealthCounts {
            healthy: 1,
            unavailable: 683,
            unknown: 341,
            observed: 1025,
            total: 1025
        }
    );
    for (glyph, row) in tile.glyphs.iter().zip(&counts.glyphs) {
        assert_eq!(row.id, glyph.id);
        assert_eq!(row.counts.total, glyph.count);
        if glyph.kind == GlyphKind::Aggregate {
            assert_eq!(row.counts.healthy, 0);
        }
        if glyph.kind == GlyphKind::Device {
            assert_eq!(glyph.id, point(300).id);
            assert_eq!(row.counts.healthy, 1);
        }
    }
    // Independent coordinate intervals exercise partial prefix sums, including
    // an interval containing the promoted device and several without it.
    for (x, y) in [
        (0, 0),
        (7, 0),
        (18, 0),
        (19, 0),
        (31, 0),
        (63, 0),
        (64, 0),
        (312_500, 312_500),
    ] {
        let cell = Cell::new(20, x, y).unwrap();
        let tile = world
            .tile(
                cell,
                Budget {
                    nodes: 9,
                    edges: 72,
                },
            )
            .unwrap();
        let actual = summary(&health.tile_health(&world, &tile.selection).unwrap());
        let mut expected = HealthCounts::default();
        for i in 0..1025 {
            let p = point(i);
            if p.x >= x * 16 && p.x < (x + 1) * 16 && p.y >= y * 16 && p.y < (y + 1) * 16 {
                expected.total += 1;
                expected.observed += 1;
                match expected_state(i) {
                    HealthState::Healthy => expected.healthy += 1,
                    HealthState::Unavailable => expected.unavailable += 1,
                    HealthState::Unknown => expected.unknown += 1,
                }
            }
        }
        assert_eq!(actual, expected);
    }
    assert_eq!(world.device_ids_page(None, 501), Err(Error::InvalidBudget));
    assert_eq!(world.device_ids_page(None, 0), Err(Error::InvalidBudget));
}

#[test]
fn invalid_batches_are_atomic_and_late_reads_do_not_undo_current_observations() {
    let world = World::new(
        "health-sequences".into(),
        24,
        (0..3).map(point).collect(),
        vec![],
    )
    .unwrap();
    let tile = world
        .tile(Cell::new(0, 0, 0).unwrap(), Budget::default())
        .unwrap();
    let mut health = HealthIndex::new(&world, 7).unwrap();
    health
        .apply(&world, 10, &[observation(0, HealthState::Healthy)])
        .unwrap();
    let result = health
        .apply(
            &world,
            9,
            &[
                observation(0, HealthState::Unavailable),
                observation(1, HealthState::Unknown),
            ],
        )
        .unwrap();
    assert_eq!((result.applied, result.stale), (1, 1));
    let unchanged = health
        .apply(&world, 11, &[observation(0, HealthState::Healthy)])
        .unwrap();
    assert_eq!(
        (unchanged.unchanged, unchanged.revision),
        (1, result.revision)
    );
    let before = health.tile_health(&world, &tile.selection).unwrap();
    assert_eq!(
        summary(&before),
        HealthCounts {
            healthy: 1,
            unknown: 2,
            observed: 2,
            total: 3,
            ..Default::default()
        }
    );
    for invalid in [
        vec![
            observation(0, HealthState::Unavailable),
            observation(0, HealthState::Unknown),
        ],
        vec![
            observation(0, HealthState::Unavailable),
            HealthObservation {
                device_id: String::new(),
                state: HealthState::Healthy,
            },
        ],
        (0..501)
            .map(|i| observation(i, HealthState::Healthy))
            .collect(),
    ] {
        assert_eq!(
            health.apply(&world, 12, &invalid),
            Err(Error::InvalidHealthUpdate)
        );
        assert_eq!(health.tile_health(&world, &tile.selection).unwrap(), before);
    }
    assert_eq!(
        health.apply(&world, 0, &[observation(0, HealthState::Unavailable)]),
        Err(Error::InvalidHealthUpdate)
    );
    assert_eq!(
        health
            .apply(&world, 12, &[observation(99, HealthState::Healthy)])
            .unwrap()
            .unknown_ids,
        1
    );
    assert_eq!(
        summary(&health.tile_health(&world, &tile.selection).unwrap()),
        summary(&before)
    );
    assert!(matches!(
        HealthIndex::new(&world, 0),
        Err(Error::InvalidHealthUpdate)
    ));
}

#[test]
fn detached_rebase_preserves_uid_state_and_rejects_old_world_resources() {
    let old_world = World::new(
        "health-before".into(),
        24,
        (0..3).map(point).collect(),
        vec![],
    )
    .unwrap();
    let old_tile = old_world
        .tile(Cell::new(0, 0, 0).unwrap(), Budget::default())
        .unwrap();
    let mut health = HealthIndex::new(&old_world, 1).unwrap();
    health
        .apply(
            &old_world,
            20,
            &[
                observation(0, HealthState::Healthy),
                observation(1, HealthState::Unavailable),
                observation(2, HealthState::Unknown),
            ],
        )
        .unwrap();
    let snapshot = health.snapshot();
    health
        .apply(&old_world, 21, &[observation(1, HealthState::Healthy)])
        .unwrap();
    let mut nodes: Vec<_> = (1..4).map(point).collect();
    nodes.reverse();
    nodes[0].label = "replacement-label.example.com".into();
    let new_world = World::new("health-after".into(), 24, nodes, vec![]).unwrap();
    let new_tile = new_world
        .tile(Cell::new(0, 0, 0).unwrap(), Budget::default())
        .unwrap();
    let mut rebased = HealthIndex::rebase(&old_world, &snapshot, &new_world, 2).unwrap();
    let result = rebased
        .tile_health(&new_world, &new_tile.selection)
        .unwrap();
    assert_eq!(
        (result.epoch, result.revision, result.observation_sequence),
        (2, 0, 20)
    );
    assert_eq!(
        summary(&result),
        HealthCounts {
            unavailable: 1,
            unknown: 2,
            observed: 2,
            total: 3,
            ..Default::default()
        }
    );
    assert_eq!(
        rebased
            .apply(&new_world, 19, &[observation(1, HealthState::Healthy)])
            .unwrap()
            .stale,
        1
    );
    assert_eq!(
        health.tile_health(&new_world, &new_tile.selection),
        Err(Error::StaleDetailRevision)
    );
    assert_eq!(health.info(&new_world), Err(Error::StaleDetailRevision));
    assert_eq!(
        rebased.tile_health(&new_world, &old_tile.selection),
        Err(Error::StaleDetailRevision)
    );
    assert_eq!(
        rebased.apply(&old_world, 22, &[observation(1, HealthState::Healthy)]),
        Err(Error::StaleDetailRevision)
    );
    assert!(matches!(
        HealthIndex::rebase(&new_world, &snapshot, &old_world, 3),
        Err(Error::StaleDetailRevision)
    ));
    let cursor = old_world.device_ids_page(None, 1).unwrap().next.unwrap();
    assert_eq!(
        new_world.device_ids_page(Some(&cursor), 1),
        Err(Error::StaleDetailRevision)
    );

    // Clipped proxies do not invent device state or lookup coverage.
    let mut left = point(10);
    left.x = 1;
    left.y = 3_000_000;
    let mut right = point(11);
    right.x = 16_000_000;
    right.y = 3_000_000;
    let edge = Relation {
        id: "invented-crossing".into(),
        source: left.id.clone(),
        target: right.id.clone(),
    };
    let crossing = World::new("crossing-health".into(), 24, vec![left, right], vec![edge]).unwrap();
    let tile = crossing
        .tile(Cell::new(2, 1, 0).unwrap(), Budget::default())
        .unwrap();
    assert!(tile.glyphs.len() >= 2 && tile.glyphs.iter().all(|g| g.kind == GlyphKind::Boundary));
    assert_eq!(
        summary(
            &HealthIndex::new(&crossing, 3)
                .unwrap()
                .tile_health(&crossing, &tile.selection)
                .unwrap()
        ),
        HealthCounts::default()
    );
}
