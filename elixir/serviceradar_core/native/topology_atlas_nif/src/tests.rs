use std::collections::BTreeMap;

use dgraph_topology::CanonicalEdge;
use serviceradar_topology_atlas::{Budget, Cell, Device};

use crate::model::{Builder, InventoryRow, PositionRow, RelationRow, SourceGraph};

fn device(id: &str) -> Device {
    Device {
        id: id.into(),
        label: id.into(),
        importance: 2,
    }
}

fn edge(source: &str, target: &str, interface: i32, rate: i64) -> CanonicalEdge {
    CanonicalEdge::new(
        source.into(),
        target.into(),
        rate,
        rate,
        rate,
        rate,
        10_000_000,
        rate > 0,
        "LLDP".into(),
        "direct-physical".into(),
        "high".into(),
        interface,
        "ethernet-a".into(),
        8,
        "ethernet-b".into(),
        "synthetic-link".into(),
        "synthetic-mutation".into(),
    )
}

fn graph(ids: &[&str], interface: i32, rate: i64) -> SourceGraph {
    let devices = ids.iter().map(|id| (id.to_string(), device(id))).collect();
    let relations = if ids.len() >= 2 {
        let row = RelationRow::canonical(edge(ids[0], ids[1], interface, rate));
        BTreeMap::from([(row.relation_id.clone(), row)])
    } else {
        BTreeMap::new()
    };
    SourceGraph { devices, relations }
}

fn imported(candidate: &crate::model::Candidate) -> Builder {
    let mut builder = Builder::new("synthetic-layout".into(), 16).unwrap();
    for rows in candidate.positions.chunks(500) {
        builder.add_positions(rows.to_vec()).unwrap();
    }
    for rows in candidate.relations.chunks(500) {
        builder.add_relations(rows.to_vec()).unwrap();
    }
    builder
}

#[test]
fn publication_preserves_reservations_and_exports_only_real_deltas() {
    let ids = [
        "sr:host0001.example.com",
        "sr:host0002.example.com",
        "sr:host0003.example.com",
    ];
    let first = Builder::new("synthetic-layout".into(), 16)
        .unwrap()
        .reconcile(graph(&ids, 3, 100))
        .unwrap();
    assert_eq!(first.world.info.node_count, 3);
    assert_eq!(first.deltas.insert_positions.len(), 3);
    let locations: BTreeMap<_, _> = first
        .positions
        .iter()
        .map(|p| (p.device_id.clone(), (p.x, p.y)))
        .collect();

    let unchanged = imported(&first).reconcile(graph(&ids, 3, 0)).unwrap();
    assert_eq!(
        first.source_digest, unchanged.source_digest,
        "rates must not publish another generation"
    );
    assert!(unchanged.deltas.insert_positions.is_empty());
    assert!(unchanged.deltas.upsert_relations.is_empty());
    assert_eq!(
        first
            .world
            .geometry
            .tile(Cell::new(0, 0, 0).unwrap(), Budget::default())
            .unwrap()
            .revision,
        unchanged
            .world
            .geometry
            .tile(Cell::new(0, 0, 0).unwrap(), Budget::default())
            .unwrap()
            .revision
    );

    let mut builder = imported(&unchanged);
    builder
        .add_inventory(vec![InventoryRow {
            id: ids[0].into(),
            label: "Synthetic router".into(),
            importance: 0,
        }])
        .unwrap();
    let changed = builder.reconcile(graph(&ids[..2], 4, 0)).unwrap();
    assert_ne!(first.source_digest, changed.source_digest);
    assert_eq!(changed.deltas.update_positions.len(), 1);
    assert_eq!(changed.deltas.update_positions[0].device_id, ids[0]);
    assert_eq!(changed.deltas.update_positions[0].min_zoom, 0);
    assert_eq!(changed.deltas.deactivate_device_ids, vec![ids[2]]);
    assert_eq!(changed.deltas.upsert_relations.len(), 1);
    assert_eq!(changed.world.info.node_count, 2);
    let active: Vec<_> = changed.positions.iter().filter(|p| p.active).collect();
    assert_eq!(
        changed.world.info.bounds,
        vec![
            vec![
                active.iter().map(|p| p.x).min().unwrap(),
                active.iter().map(|p| p.y).min().unwrap()
            ],
            vec![
                active.iter().map(|p| p.x).max().unwrap(),
                active.iter().map(|p| p.y).max().unwrap()
            ],
        ],
        "Fit bounds exclude inactive reservations"
    );
    assert!(changed.world.geometry.search(ids[2]).is_none());
    for row in &changed.positions {
        assert_eq!((row.x, row.y), locations[&row.device_id]);
    }

    let restored = imported(&changed).reconcile(graph(&ids, 4, 10)).unwrap();
    assert_eq!(restored.deltas.activate_device_ids, vec![ids[2]]);
    assert!(restored.deltas.insert_positions.is_empty());
    for row in &restored.positions {
        assert_eq!((row.x, row.y), locations[&row.device_id]);
    }
    let cold = imported(&restored).finish().unwrap();
    assert_eq!(
        cold.geometry.search(ids[2]),
        restored.world.geometry.search(ids[2])
    );
    assert_eq!(cold.relations, restored.relations);
}

#[test]
fn interface_binding_changes_publish_without_invalidating_geometry() {
    // Source sorts after target: reversing by name would put index3 on the
    // wrong endpoint. Restart and delta export must retain the original sides.
    let ids = ["sr:host0009.example.com", "sr:host0002.example.com"];
    let initial = Builder::new("synthetic-layout".into(), 16)
        .unwrap()
        .reconcile(graph(&ids, 3, 0))
        .unwrap();
    let changed = imported(&initial).reconcile(graph(&ids, 19, 5)).unwrap();
    let row = &changed.relations[0];
    assert_eq!(
        (&row.source_id, &row.target_id),
        (&ids[0].to_owned(), &ids[1].to_owned())
    );
    assert_eq!(
        (row.source_if_index, row.target_if_index),
        (Some(19), Some(8))
    );
    assert_eq!(
        (row.source_if_name.as_deref(), row.target_if_name.as_deref()),
        (Some("ethernet-a"), Some("ethernet-b"))
    );
    assert_ne!(initial.source_digest, changed.source_digest);
    assert_eq!(changed.deltas.upsert_relations.len(), 1);
    let root = Cell::new(0, 0, 0).unwrap();
    assert_eq!(
        initial
            .world
            .geometry
            .tile(root, Budget::default())
            .unwrap()
            .revision,
        changed
            .world
            .geometry
            .tile(root, Budget::default())
            .unwrap()
            .revision
    );
    let removed = imported(&changed)
        .reconcile(graph(&ids[..1], 3, 0))
        .unwrap();
    assert_eq!(
        removed.deltas.deactivate_relation_ids,
        vec!["synthetic-link"]
    );
}

#[test]
fn rejected_import_is_atomic_and_inactive_points_remain_reserved() {
    let first = Builder::new("synthetic-layout".into(), 16)
        .unwrap()
        .reconcile(graph(&["sr:host0001.example.com"], 3, 0))
        .unwrap();
    let mut builder = Builder::new("synthetic-layout".into(), 16).unwrap();
    let old = first.positions[0].clone();
    let width = 1u32 << (24 - old.component_z);
    let oversized = (0..501)
        .map(|i| PositionRow {
            device_id: format!("sr:host{:04}.example.com", i + 1),
            x: old.component_x * width + i + 1,
            ..old.clone()
        })
        .collect();
    assert!(builder.add_positions(oversized).is_err());
    assert!(builder
        .add_positions(vec![old.clone(), old.clone()])
        .is_err());
    builder
        .add_positions(vec![PositionRow {
            active: false,
            ..old.clone()
        }])
        .unwrap();
    let changed = builder
        .reconcile(graph(&["sr:host0002.example.com"], 3, 0))
        .unwrap();
    assert_eq!(changed.positions.len(), 2);
    let replacement = changed
        .world
        .geometry
        .search("sr:host0002.example.com")
        .unwrap();
    assert_ne!((replacement.x, replacement.y), (old.x, old.y));
    assert!(changed.world.geometry.search(&old.device_id).is_none());
    assert_eq!(
        crate::model::page_range(501, 0, 500).unwrap(),
        (0..500, Some(500))
    );
    assert_eq!(
        crate::model::page_range(501, 500, 500).unwrap(),
        (500..501, None)
    );
    for (cursor, limit) in [(502, 500), (0, 0), (0, 501)] {
        assert!(crate::model::page_range(501, cursor, limit).is_err());
    }
}
