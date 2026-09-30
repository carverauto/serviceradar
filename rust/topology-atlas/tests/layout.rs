#[path = "../fixtures/hierarchy.rs"]
mod hierarchy;
use hierarchy::COUNT;

use std::collections::{HashMap, HashSet};
use std::time::Instant;

use serviceradar_topology_atlas::{
    Budget, Cell, Device, GlyphKind, HealthIndex, HealthObservation, HealthState, Relation,
    WORLD_EXTENT, World, reconcile,
};

fn device(id: &str, importance: u8) -> Device {
    Device {
        id: id.into(),
        label: id.strip_prefix("sr:").unwrap_or(id).into(),
        importance,
    }
}

fn relation(source: &str, target: &str) -> Relation {
    Relation {
        id: format!("{source}/{target}"),
        source: source.into(),
        target: target.into(),
    }
}

#[test]
fn elk_reconciliation_does_not_depend_on_the_callers_stack_size() {
    // Native callers include BEAM dirty schedulers, whose stacks are smaller
    // than ordinary Rust test threads. Exercise the real ELK runtime there.
    std::thread::Builder::new()
        .stack_size(128 * 1024)
        .spawn(|| {
            let nodes: Vec<_> = (0..384)
                .map(|n| device(&format!("sr:chain-{n:03}.example.test"), 1))
                .collect();
            let links: Vec<_> = nodes
                .windows(2)
                .map(|pair| relation(&pair[0].id, &pair[1].id))
                .collect();
            let placed = reconcile(nodes.clone(), &links, &[]).unwrap();
            assert_eq!(placed.len(), nodes.len());
            assert_eq!(
                placed
                    .iter()
                    .map(|p| (p.x, p.y))
                    .collect::<HashSet<_>>()
                    .len(),
                nodes.len()
            );
            assert_eq!(reconcile(nodes, &links, &placed).unwrap(), placed);
        })
        .unwrap()
        .join()
        .unwrap();
}

#[test]
fn deterministic_world_preserves_positions_parents_and_tombstones() {
    let nodes = vec![
        device("sr:core.example.test", 0),
        device("sr:access.example.test", 1),
        device("sr:endpoint.example.test", 2),
        device("sr:island.example.test", 1),
    ];
    let links = vec![
        relation(&nodes[0].id, &nodes[1].id),
        relation(&nodes[1].id, &nodes[2].id),
    ];
    let original = reconcile(nodes.clone(), &links, &[]).unwrap();
    assert_eq!(
        original,
        reconcile(
            nodes.iter().cloned().rev().collect(),
            &links.iter().cloned().rev().collect::<Vec<_>>(),
            &[]
        )
        .unwrap()
    );
    assert_eq!(
        original
            .iter()
            .map(|p| (&p.id, p.min_zoom))
            .collect::<HashMap<_, _>>()[&nodes[2].id],
        8
    );

    // Inserting a lower-sorted ID, merging components, and deleting a node must
    // not repack or reparent any existing device.
    let added = device("sr:000-new.example.test", 2);
    let mut changed: Vec<_> = nodes
        .iter()
        .filter(|n| n.id != nodes[2].id)
        .cloned()
        .collect();
    changed.push(added.clone());
    let changed_links = vec![
        links[0].clone(),
        relation(&nodes[1].id, &added.id),
        relation(&nodes[0].id, &nodes[3].id),
    ];
    let current = reconcile(changed.clone(), &changed_links, &original).unwrap();
    for previous in original.iter().filter(|p| p.id != nodes[2].id) {
        assert_eq!(current.iter().find(|p| p.id == previous.id), Some(previous));
    }
    let retired = original.iter().find(|p| p.id == nodes[2].id).unwrap();
    let inserted = current.iter().find(|p| p.id == added.id).unwrap();
    assert_ne!((inserted.x, inserted.y), (retired.x, retired.y));

    let mut persisted = original.clone();
    persisted.push(inserted.clone());
    changed.push(nodes[2].clone());
    let returned = reconcile(changed, &[], &persisted).unwrap();
    assert_eq!(returned.iter().find(|p| p.id == retired.id), Some(retired));
    let original_components: HashSet<_> = original.iter().map(|p| &p.component_id).collect();
    assert_eq!(original_components.len(), 2);
}

#[test]
fn fresh_elk_component_keeps_unique_centers_in_a_crowded_world() {
    // One free z=11 cell remains. Coarser siblings occupy every other branch,
    // so the area walk's next fresh component is a z=12 cell of width 4096.
    let mut previous = Vec::new();
    for z in 1..=11 {
        for (dx, dy) in [(1u32, 0u32), (0, 1), (1, 1)] {
            let cell = Cell::new(z, dx, dy).unwrap();
            let (left, top) = cell.origin();
            let mid = cell.width() / 2;
            let id = format!("sr:reserved-{z}-{dx}-{dy}.example.test");
            previous.push(serviceradar_topology_atlas::Position {
                id: id.clone(),
                label: id,
                x: left + mid,
                y: top + mid,
                min_zoom: 0,
                parent_id: None,
                component_id: format!("sr:reserved-component-{z}-{dx}-{dy}.example.test"),
                component: cell,
                placement_depth: 1,
            });
        }
    }
    let hub = device("sr:hub-46772.example.test", 0);
    let mut nodes = vec![hub.clone()];
    nodes.extend((0..25_000).map(|n| device(&format!("sr:spoke-{n:05}.example.test"), 2)));
    let links: Vec<_> = nodes[1..]
        .iter()
        .map(|spoke| relation(&hub.id, &spoke.id))
        .collect();
    let placed = reconcile(nodes, &links, &previous).unwrap();
    let component = placed[0].component;
    assert!(
        placed
            .iter()
            .all(|p| p.component == component && component.contains(p.x, p.y)),
        "star leaked outside {component:?}"
    );
    assert_eq!(
        placed
            .iter()
            .map(|p| (p.x, p.y))
            .collect::<HashSet<_>>()
            .len(),
        placed.len()
    );
    let reserved: HashSet<_> = previous.iter().map(|p| p.component).collect();
    assert!(
        !reserved.contains(&component),
        "fresh star reused a frozen reservation: {component:?}"
    );
    assert!(
        placed
            .iter()
            .all(|p| previous.iter().all(|old| old.x != p.x || old.y != p.y)),
        "fresh star occupied a frozen coordinate"
    );
}

#[test]
fn elk_radial_geometry_survives_tiling_with_named_endpoint_devices() {
    let root = device("sr:root.example.test", 0);
    let mut nodes = vec![root.clone()];
    nodes.extend((0..40).map(|n| device(&format!("sr:leaf-{n:02}.example.test"), 2)));
    let links: Vec<_> = nodes[1..]
        .iter()
        .map(|n| relation(&root.id, &n.id))
        .collect();
    let points = reconcile(nodes.clone(), &links, &[]).unwrap();
    let center = points.iter().find(|p| p.id == root.id).unwrap();
    let distances: Vec<_> = points
        .iter()
        .filter(|p| p.id != root.id)
        .map(|p| (f64::from(p.x) - f64::from(center.x)).hypot(f64::from(p.y) - f64::from(center.y)))
        .collect();
    let minimum = distances.iter().copied().fold(f64::INFINITY, f64::min);
    let maximum = distances.iter().copied().fold(0.0, f64::max);
    assert!(
        minimum > 0.0 && maximum / minimum < 1.001,
        "ELK leaves occupy one radial level: {distances:?}"
    );
    let world = World::new("radial-synthetic".into(), 16, points.clone(), links).unwrap();
    // Fit this component into one 512-pixel tile: adjacent ELK leaves are
    // readable here, long before the legacy absolute endpoint zoom of eight.
    let fitted = world.tile(center.component, Budget::default()).unwrap();
    assert_eq!(
        fitted
            .glyphs
            .iter()
            .filter(|g| g.kind == GlyphKind::Device)
            .count(),
        points.len(),
        "readable radial leaves must not remain count-of-a-few aggregates"
    );
    let overview = world
        .tile(Cell::new(0, 0, 0).unwrap(), Budget::default())
        .unwrap();
    assert_eq!(overview.device_count, nodes.len() as u64);
    for glyph in &overview.glyphs {
        if glyph.kind == GlyphKind::Device {
            let point = points.iter().find(|p| p.id == glyph.id).unwrap();
            assert_eq!(glyph.label, point.label);
            assert_eq!((glyph.x, glyph.y), (f64::from(point.x), f64::from(point.y)));
        }
    }
    for point in &points {
        let tile = world
            .tile(
                Cell::at_point(16, point.x, point.y).unwrap(),
                Budget::default(),
            )
            .unwrap();
        let glyph = tile
            .glyphs
            .iter()
            .find(|glyph| glyph.kind == GlyphKind::Device && glyph.id == point.id)
            .unwrap();
        assert_eq!(glyph.label, point.label);
        assert_eq!((glyph.x, glyph.y), (f64::from(point.x), f64::from(point.y)));
    }
}

#[test]
fn disconnected_devices_do_not_shrink_the_connected_radial_overview() {
    let hub = device("sr:overview-hub.example.test", 0);
    let mut nodes = vec![hub.clone()];
    nodes.extend((0..40).map(|n| device(&format!("sr:overview-leaf-{n:02}.example.test"), 2)));
    let links: Vec<_> = nodes[1..]
        .iter()
        .map(|node| relation(&hub.id, &node.id))
        .collect();
    nodes.extend((0..24).map(|n| device(&format!("sr:isolated-{n:02}.example.test"), 2)));
    let points = reconcile(nodes.clone(), &links, &[]).unwrap();
    let span = |xs: Vec<u32>| xs.iter().max().unwrap() - xs.iter().min().unwrap();
    let occupied = span(points.iter().map(|p| p.x).collect());
    let connected = span(
        points
            .iter()
            .filter(|p| p.component_id == hub.id)
            .map(|p| p.x)
            .collect(),
    );
    assert!(
        connected * 3 > occupied * 2,
        "a connected radial fan must retain useful Fit scale: connected={connected}, world={occupied}"
    );
    assert_eq!(points.iter().filter(|p| p.parent_id.is_none()).count(), 25);
    assert_eq!(
        points
            .iter()
            .map(|p| &p.component_id)
            .collect::<HashSet<_>>()
            .len(),
        25
    );
    assert_eq!(reconcile(nodes, &links, &points).unwrap(), points);
}

#[test]
fn fresh_elk_component_keeps_unique_centers_in_a_crowded_world() {
    // One free z=11 cell remains. Coarser siblings occupy every other branch,
    // so the area walk's next fresh component is a z=12 cell of width 4096.
    let mut previous = Vec::new();
    for z in 1..=11 {
        for (dx, dy) in [(1u32, 0u32), (0, 1), (1, 1)] {
            let cell = Cell::new(z, dx, dy).unwrap();
            let (left, top) = cell.origin();
            let mid = cell.width() / 2;
            let id = format!("sr:reserved-{z}-{dx}-{dy}.example.test");
            previous.push(serviceradar_topology_atlas::Position {
                id: id.clone(),
                label: id,
                x: left + mid,
                y: top + mid,
                min_zoom: 0,
                parent_id: None,
                component_id: format!("sr:reserved-component-{z}-{dx}-{dy}.example.test"),
                component: cell,
                placement_depth: 1,
            });
        }
    }
    let hub = device("sr:hub-46772.example.test", 0);
    let mut nodes = vec![hub.clone()];
    nodes.extend((0..25_000).map(|n| device(&format!("sr:spoke-{n:05}.example.test"), 2)));
    let links: Vec<_> = nodes[1..]
        .iter()
        .map(|spoke| relation(&hub.id, &spoke.id))
        .collect();
    let placed = reconcile(nodes, &links, &previous).unwrap();
    let component = placed[0].component;
    assert!(
        placed
            .iter()
            .all(|p| p.component == component && component.contains(p.x, p.y)),
        "star leaked outside {component:?}"
    );
    assert_eq!(
        placed
            .iter()
            .map(|p| (p.x, p.y))
            .collect::<HashSet<_>>()
            .len(),
        placed.len()
    );
    let reserved: HashSet<_> = previous.iter().map(|p| p.component).collect();
    assert!(
        !reserved.contains(&component),
        "fresh star reused a frozen reservation: {component:?}"
    );
    assert!(
        placed
            .iter()
            .all(|p| previous.iter().all(|old| old.x != p.x || old.y != p.y)),
        "fresh star occupied a frozen coordinate"
    );
}

#[test]
fn elk_radial_geometry_survives_tiling_with_named_endpoint_devices() {
    let root = device("sr:root.example.test", 0);
    let mut nodes = vec![root.clone()];
    nodes.extend((0..40).map(|n| device(&format!("sr:leaf-{n:02}.example.test"), 2)));
    let links: Vec<_> = nodes[1..]
        .iter()
        .map(|n| relation(&root.id, &n.id))
        .collect();
    let points = reconcile(nodes.clone(), &links, &[]).unwrap();
    let center = points.iter().find(|p| p.id == root.id).unwrap();
    let distances: Vec<_> = points
        .iter()
        .filter(|p| p.id != root.id)
        .map(|p| (f64::from(p.x) - f64::from(center.x)).hypot(f64::from(p.y) - f64::from(center.y)))
        .collect();
    let minimum = distances.iter().copied().fold(f64::INFINITY, f64::min);
    let maximum = distances.iter().copied().fold(0.0, f64::max);
    assert!(
        minimum > 0.0 && maximum / minimum < 1.001,
        "ELK leaves occupy one radial level: {distances:?}"
    );
    let world = World::new("radial-synthetic".into(), 16, points.clone(), links).unwrap();
    // Fit this component into one 512-pixel tile: adjacent ELK leaves are
    // readable here, long before the legacy absolute endpoint zoom of eight.
    let fitted = world.tile(center.component, Budget::default()).unwrap();
    assert_eq!(
        fitted.glyphs.iter().filter(|g| g.kind == GlyphKind::Device).count(),
        points.len(),
        "readable radial leaves must not remain count-of-a-few aggregates"
    );
    let overview = world
        .tile(Cell::new(0, 0, 0).unwrap(), Budget::default())
        .unwrap();
    assert_eq!(overview.device_count, nodes.len() as u64);
    for glyph in &overview.glyphs {
        if glyph.kind == GlyphKind::Device {
            let point = points.iter().find(|p| p.id == glyph.id).unwrap();
            assert_eq!(glyph.label, point.label);
            assert_eq!((glyph.x, glyph.y), (f64::from(point.x), f64::from(point.y)));
        }
    }
    for point in &points {
        let tile = world
            .tile(
                Cell::at_point(16, point.x, point.y).unwrap(),
                Budget::default(),
            )
            .unwrap();
        let glyph = tile
            .glyphs
            .iter()
            .find(|glyph| glyph.kind == GlyphKind::Device && glyph.id == point.id)
            .unwrap();
        assert_eq!(glyph.label, point.label);
        assert_eq!((glyph.x, glyph.y), (f64::from(point.x), f64::from(point.y)));
    }
}

#[test]
fn invented_million_device_hierarchy_and_one_percent_growth() {
    let (mut nodes, mut links) = hierarchy::hierarchy();
    let started = Instant::now();
    let world = reconcile(nodes.clone(), &links, &[]).unwrap();
    eprintln!(
        "synthetic layout: nodes={} relations={} elapsed_ms={}",
        world.len(),
        links.len(),
        started.elapsed().as_millis()
    );
    assert_eq!(world.len(), COUNT);
    assert_eq!(
        world
            .iter()
            .map(|p| &p.component_id)
            .collect::<HashSet<_>>()
            .len(),
        1,
        "the invented million-device network is connected"
    );
    assert_eq!(
        world
            .iter()
            .map(|p| (p.x, p.y))
            .collect::<HashSet<_>>()
            .len(),
        COUNT
    );
    assert!(
        world
            .iter()
            .all(|p| p.x < WORLD_EXTENT && p.y < WORLD_EXTENT && p.component.contains(p.x, p.y))
    );

    for i in 0..COUNT / 100 {
        let node = device(&format!("sr:added-{i:07}.example.test"), 2);
        // Concentrated fanout tests vacant-slot allocation as well as growth.
        links.push(relation(&node.id, &nodes[0].id));
        nodes.push(node);
    }
    let started = Instant::now();
    let updated = reconcile(nodes, &links, &world).unwrap();
    eprintln!(
        "synthetic incremental layout: nodes={} elapsed_ms={}",
        updated.len(),
        started.elapsed().as_millis()
    );
    let by_id: HashMap<_, _> = updated.iter().map(|p| (p.id.as_str(), p)).collect();
    assert_eq!(updated.len(), COUNT + COUNT / 100);
    for old in &world {
        assert_eq!(by_id.get(old.id.as_str()), Some(&old));
    }
    assert_eq!(
        updated
            .iter()
            .map(|p| (p.x, p.y))
            .collect::<HashSet<_>>()
            .len(),
        updated.len()
    );
    drop(by_id);
    drop(updated);
    links.truncate(COUNT * 2);
    let samples: Vec<_> = world
        .iter()
        .step_by(COUNT / 16)
        .map(|p| (p.x, p.y))
        .collect();
    let started = Instant::now();
    let indexed = World::new("million-synthetic".into(), 16, world, links).unwrap();
    eprintln!(
        "synthetic spatial index: elapsed_ms={}",
        started.elapsed().as_millis()
    );
    let started = Instant::now();
    let budget = Budget::default();
    let overview = indexed.tile(Cell::new(0, 0, 0).unwrap(), budget).unwrap();
    assert_eq!(overview.device_count, COUNT as u64);
    assert!(overview.glyphs.len() <= budget.nodes && overview.edges.len() <= budget.edges);
    eprintln!(
        "synthetic overview generation: elapsed_ms={} candidates={}",
        started.elapsed().as_millis(),
        overview.candidate_relations
    );
    let mut latency = Vec::new();
    let mut candidates = Vec::new();
    for z in [4, 8, 12, 16] {
        for &(x, y) in &samples {
            let started = Instant::now();
            let tile = indexed
                .tile(Cell::at_point(z, x, y).unwrap(), budget)
                .unwrap();
            latency.push(started.elapsed().as_micros());
            candidates.push(tile.candidate_relations);
            assert!(tile.glyphs.len() <= budget.nodes && tile.edges.len() <= budget.edges);
            assert!(tile.device_count > 0);
        }
    }
    latency.sort_unstable();
    candidates.sort_unstable();
    eprintln!(
        "synthetic tile generation only: samples={} p95_us={} max_us={} p95_candidates={} max_candidates={}",
        latency.len(),
        latency[latency.len() * 95 / 100],
        latency.last().unwrap(),
        candidates[candidates.len() * 95 / 100],
        candidates.last().unwrap()
    );

    // Availability uses the same million-device owner fixture and native index.
    // Measurements are emitted evidence, not platform-dependent timing gates.
    let started = Instant::now();
    let mut health = HealthIndex::new(&indexed, 1).unwrap();
    eprintln!(
        "synthetic health allocation: elapsed_us={} retained_bytes={}",
        started.elapsed().as_micros(),
        health.retained_bytes()
    );
    assert!(health.retained_bytes() < COUNT * 22);
    let started = Instant::now();
    let mut cursor = None;
    let mut sequence = 0;
    let mut seeded = 0;
    loop {
        let page = indexed.device_ids_page(cursor.as_ref(), 500).unwrap();
        let rows: Vec<_> = page
            .ids
            .into_iter()
            .map(|device_id| HealthObservation {
                device_id,
                state: HealthState::Healthy,
            })
            .collect();
        sequence += 1;
        seeded += health.apply(&indexed, sequence, &rows).unwrap().applied;
        cursor = page.next;
        if cursor.is_none() {
            break;
        }
    }
    assert_eq!(seeded, COUNT);
    eprintln!(
        "synthetic health full seed: elapsed_ms={}",
        started.elapsed().as_millis()
    );
    let rows: Vec<_> = indexed
        .device_ids_page(None, 500)
        .unwrap()
        .ids
        .into_iter()
        .map(|device_id| HealthObservation {
            device_id,
            state: HealthState::Unavailable,
        })
        .collect();
    let started = Instant::now();
    assert_eq!(
        health.apply(&indexed, sequence + 1, &rows).unwrap().applied,
        500
    );
    eprintln!(
        "synthetic health update500: elapsed_us={}",
        started.elapsed().as_micros()
    );
    let mut summary_latency = Vec::new();
    for _ in 0..64 {
        let started = Instant::now();
        let summary = health.tile_health(&indexed, &overview.selection).unwrap();
        summary_latency.push(started.elapsed().as_micros());
        assert_eq!(
            summary.glyphs.iter().map(|g| g.counts.healthy).sum::<u64>(),
            COUNT as u64 - 500
        );
        assert_eq!(
            summary
                .glyphs
                .iter()
                .map(|g| g.counts.unavailable)
                .sum::<u64>(),
            500
        );
        assert_eq!(
            summary
                .glyphs
                .iter()
                .map(|g| g.counts.observed)
                .sum::<u64>(),
            COUNT as u64
        );
    }
    summary_latency.sort_unstable();
    eprintln!(
        "synthetic health overview64: p95_us={} max_us={}",
        summary_latency[summary_latency.len() * 95 / 100],
        summary_latency.last().unwrap()
    );
    let started = Instant::now();
    let snapshot = health.snapshot();
    eprintln!(
        "synthetic health snapshot: elapsed_us={} retained_bytes={}",
        started.elapsed().as_micros(),
        snapshot.retained_bytes()
    );
    assert!(snapshot.retained_bytes() < COUNT * 10);
    let started = Instant::now();
    // Fully retained membership measures the full UID-remap path without
    // constructing a second million-node graph merely for availability tests.
    let rebased = HealthIndex::rebase(&indexed, &snapshot, &indexed, 2).unwrap();
    eprintln!(
        "synthetic health rebase1M: elapsed_ms={} retained_bytes={}",
        started.elapsed().as_millis(),
        rebased.retained_bytes()
    );
    assert_eq!(
        rebased
            .tile_health(&indexed, &overview.selection)
            .unwrap()
            .glyphs,
        health
            .tile_health(&indexed, &overview.selection)
            .unwrap()
            .glyphs
    );
}
