use std::collections::{BTreeMap, BTreeSet};

use dgraph_topology::{CanonicalDevice, CanonicalEdge, NeighbourhoodEdge, TopologyView};
use serviceradar_topology_atlas::{Budget, Cell, DetailScope, Device, TopologyClass};

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
        true,
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
    SourceGraph {
        devices,
        relations,
        raw_links: u64::from(ids.len() >= 2),
    }
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

fn canonical_device(id: &str, hostname: &str) -> CanonicalDevice {
    serde_json::from_value(serde_json::json!({"device.id": id, "device.hostname": hostname}))
        .unwrap()
}

fn view_edge(
    kind: &str,
    id: &str,
    (source, source_index, source_name): (&str, i32, &str),
    (target, target_index, target_name): (&str, i32, &str),
    class: &str,
    eligible: bool,
) -> NeighbourhoodEdge {
    NeighbourhoodEdge::new(
        kind,
        CanonicalEdge::new(
            source.into(),
            target.into(),
            0,
            0,
            0,
            0,
            10_000_000,
            eligible,
            "lldp".into(),
            class.into(),
            "high".into(),
            source_index,
            source_name.into(),
            target_index,
            target_name.into(),
            id.into(),
            "synthetic-mutation".into(),
        ),
    )
}

#[test]
fn attachment_fan_joins_the_world_tile_without_inflating_degree() {
    let ap = "sr:ap-1.example.test";
    let peer = "sr:peer-1.example.test";
    let endpoint_a = "sr:endpoint-a.example.test";
    let endpoint_b = "sr:endpoint-b.example.test";
    let view = TopologyView::new(
        vec![
            canonical_device(ap, "ap-1"),
            canonical_device(peer, "peer-1"),
            canonical_device(endpoint_a, "endpoint-a"),
            canonical_device(endpoint_b, "endpoint-b"),
        ],
        vec![
            view_edge(
                "CANONICAL_TOPOLOGY",
                "backbone",
                (ap, 5, "ge-0/0/1"),
                (peer, 9, "ge-0/0/9"),
                "direct-physical",
                true,
            ),
            view_edge(
                "ATTACHED_TO",
                "attach-a",
                (ap, 5, "ge-0/0/1"),
                (endpoint_a, 1, "eth0"),
                "direct-physical",
                true,
            ),
            view_edge(
                "INFERRED_TO",
                "attach-b",
                (ap, 5, "ge-0/0/1"),
                (endpoint_b, 2, "eth1"),
                "direct-physical",
                true,
            ),
        ],
    );
    let candidate = Builder::new("synthetic-layout".into(), 16)
        .unwrap()
        .reconcile(SourceGraph::from_view(view).unwrap())
        .unwrap();
    let tile = candidate
        .world
        .geometry
        .tile(Cell::new(0, 0, 0).unwrap(), Budget::default())
        .unwrap();
    assert_eq!(tile.device_count, 4);
    let drawn = tile.edges.iter().map(|edge| edge.count).sum::<u64>() + tile.internal_relations;
    assert_eq!(drawn, 3);
    for id in [ap, peer, endpoint_a, endpoint_b] {
        assert!(candidate.world.geometry.search(id).is_some(), "{id}");
    }
    assert!(candidate
        .relations
        .iter()
        .any(|row| row.relation_id == "attach-a"
            && row.kind == "ATTACHED_TO"
            && !row.telemetry_eligible));
    assert!(candidate
        .relations
        .iter()
        .any(|row| row.relation_id == "attach-b" && !row.telemetry_eligible));
    let backbone = candidate
        .relations
        .iter()
        .position(|row| row.relation_id == "backbone")
        .unwrap();
    assert!(candidate.relations[backbone].telemetry_eligible);
    assert_eq!(candidate.world.interface_degrees[backbone], [1, 1]);
}

#[test]
fn duplicate_physical_evidence_collapses_without_merging_parallel_ports() {
    let a = "sr:a.example.test";
    let b = "sr:b.example.test";
    let c = "sr:c.example.test";
    let positions = Builder::new("synthetic-layout".into(), 16)
        .unwrap()
        .reconcile(graph(&[a, b, c], 3, 1))
        .unwrap()
        .positions;
    let rows = vec![
        physical("link-ba", b, a, 9, "ge-0/0/2", 5, "ge-0/0/1"),
        physical("link-names", a, b, 0, "ge-0/0/1", 0, "ge-0/0/2"),
        physical("link-ab", a, b, 5, "ge-0/0/1", 9, "ge-0/0/2"),
        physical("link-index-alias", a, b, 5, "uplink-a", 9, "uplink-b"),
        physical("link-partial-source", a, b, 5, "uplink-a", 0, "uplink-b"),
        physical("link-partial-target", b, a, 9, "uplink-b", 0, "uplink-a"),
        physical("link-parallel", a, b, 6, "ge-0/0/3", 10, "ge-0/0/4"),
        physical("link-shared-parallel", a, b, 5, "ge-0/0/1", 20, "ge-0/0/9"),
        physical("alias-a", a, b, 7, "port-a", 11, "port-b"),
        physical("alias-b", a, b, 8, "port-a", 12, "port-b"),
        physical("alias-unresolved", a, b, 0, "port-a", 0, "port-b"),
        physical("link-unrelated", a, b, 0, "ge-0/0/7", 0, "ge-0/0/8"),
        {
            let mut row = physical("link-shared", a, c, 5, "ge-0/0/1", 1, "eth0");
            row.telemetry_eligible = false;
            row
        },
    ];
    let mut cold = Builder::new("synthetic-layout".into(), 16).unwrap();
    cold.add_positions(positions.clone()).unwrap();
    cold.add_relations(rows.clone()).unwrap();
    let world = cold.finish().unwrap();
    let ids: Vec<_> = world
        .relations
        .iter()
        .map(|row| row.relation_id.as_str())
        .collect();
    assert_eq!(
        ids,
        vec![
            "alias-a",
            "alias-b",
            "alias-unresolved",
            "link-ab",
            "link-parallel",
            "link-shared",
            "link-shared-parallel",
            "link-unrelated"
        ]
    );
    let degree = |id: &str| {
        let index = world
            .relations
            .iter()
            .position(|row| row.relation_id == id)
            .unwrap();
        world.interface_degrees[index]
    };
    assert_eq!(degree("link-ab"), [3, 1]);
    assert_eq!(degree("link-parallel"), [1, 1]);
    assert_eq!(degree("link-shared"), [3, 1]);
    assert_eq!(degree("link-shared-parallel"), [3, 1]);
    assert_eq!(degree("link-unrelated"), [0, 0]);
    let p = world.geometry.search(a).unwrap();
    let tile = world
        .geometry
        .tile(Cell::at_point(16, p.x, p.y).unwrap(), Budget::default())
        .unwrap();
    let selected = world
        .geometry
        .tile_relations(&tile.selection, None, 256)
        .unwrap();
    for id in ["link-ab", "link-parallel", "link-shared-parallel"] {
        assert!(selected.relations.iter().any(|row| row.relation_id == id));
    }
    assert_eq!(
        world
            .relations
            .iter()
            .find(|row| row.relation_id == "link-ab")
            .unwrap()
            .source_if_index,
        Some(5)
    );

    let mut persisted = Builder::new("synthetic-layout".into(), 16).unwrap();
    persisted.add_positions(positions).unwrap();
    persisted
        .add_relations(vec![
            physical("link-ba", b, a, 9, "ge-0/0/2", 5, "ge-0/0/1"),
            physical("link-ab", a, b, 5, "ge-0/0/1", 9, "ge-0/0/2"),
        ])
        .unwrap();
    let mut relations = BTreeMap::new();
    for row in [
        physical("link-ba", b, a, 9, "ge-0/0/2", 5, "ge-0/0/1"),
        physical("link-ab", a, b, 5, "ge-0/0/1", 9, "ge-0/0/2"),
        physical("link-index-alias", a, b, 5, "uplink-a", 9, "uplink-b"),
        physical("link-partial-source", a, b, 5, "uplink-a", 0, "uplink-b"),
        physical("link-partial-target", b, a, 9, "uplink-b", 0, "uplink-a"),
    ] {
        relations.insert(row.relation_id.clone(), row);
    }
    let devices = [a, b, c]
        .into_iter()
        .map(|id| (id.to_owned(), device(id)))
        .collect();
    let raw_links = relations.len() as u64;
    let candidate = persisted
        .reconcile(SourceGraph {
            devices,
            relations,
            raw_links,
        })
        .unwrap();
    assert_eq!(candidate.relations.len(), 1);
    assert!(candidate.relations[0].telemetry_eligible);
    assert_eq!(
        candidate.deltas.deactivate_relation_ids,
        vec!["link-ba".to_owned()]
    );
    assert_eq!(candidate.world.interface_degrees, vec![[1, 1]]);
}

fn physical(
    id: &str,
    source: &str,
    target: &str,
    source_index: i32,
    source_name: &str,
    target_index: i32,
    target_name: &str,
) -> RelationRow {
    RelationRow::canonical(CanonicalEdge::new(
        source.into(),
        target.into(),
        0,
        0,
        0,
        0,
        10_000_000,
        true,
        "lldp".into(),
        "direct-physical".into(),
        "high".into(),
        source_index,
        source_name.into(),
        target_index,
        target_name.into(),
        id.into(),
        "synthetic-mutation".into(),
    ))
}

#[test]
fn physical_forest_wins_over_an_inferred_shortcut() {
    let ids = [
        "sr:router.example.test",
        "sr:access.example.test",
        "sr:leaf.example.test",
    ];
    let edges = vec![
        view_edge(
            "CANONICAL_TOPOLOGY",
            "physical-ra",
            (ids[0], 1, "p1"),
            (ids[1], 1, "p1"),
            "direct-physical",
            true,
        ),
        view_edge(
            "CANONICAL_TOPOLOGY",
            "physical-al",
            (ids[1], 2, "p2"),
            (ids[2], 1, "p1"),
            "direct-physical",
            true,
        ),
        view_edge(
            "INFERRED_TO",
            "inferred-rl",
            (ids[0], 0, ""),
            (ids[2], 0, ""),
            "inferred",
            false,
        ),
        view_edge(
            "ATTACHED_TO",
            "inferred-ra",
            (ids[0], 0, ""),
            (ids[1], 0, ""),
            "inferred-segment",
            false,
        ),
    ];
    let view = TopologyView::new(
        ids.iter().map(|id| canonical_device(id, id)).collect(),
        edges,
    );
    let mut builder = Builder::new("synthetic-forest".into(), 16).unwrap();
    builder
        .add_inventory(
            ids.iter()
                .enumerate()
                .map(|(i, id)| InventoryRow {
                    id: (*id).into(),
                    label: (*id).into(),
                    importance: if i == 0 { 0 } else { 1 },
                })
                .collect(),
        )
        .unwrap();
    let candidate = builder
        .reconcile(SourceGraph::from_view(view).unwrap())
        .unwrap();
    let leaf = candidate
        .positions
        .iter()
        .find(|row| row.device_id == ids[2])
        .unwrap();
    assert_eq!(leaf.parent_id.as_deref(), Some(ids[1]));
    assert_eq!(candidate.world.relations.len(), 4);
    // Reload keeps every cross-link while preserving the already authored tree.
    let mut cold = Builder::new("synthetic-forest".into(), 16).unwrap();
    cold.add_positions(candidate.positions).unwrap();
    cold.add_relations(candidate.relations.to_vec()).unwrap();
    let restored = cold.finish().unwrap();
    assert_eq!(restored.relations.len(), 4);
    let detail = restored
        .geometry
        .detail(&DetailScope::Neighborhood(ids[0].into()), None)
        .unwrap();
    assert_eq!(detail.relations.len(), 4);
    for z in [0, 8, 16] {
        let p = restored.geometry.search(ids[0]).unwrap();
        let tile = restored
            .geometry
            .tile(Cell::at_point(z, p.x, p.y).unwrap(), Budget::default())
            .unwrap();
        let page = restored
            .geometry
            .tile_relations(&tile.selection, None, 256)
            .unwrap();
        assert!(page.next.is_none());
        assert!(page
            .relations
            .iter()
            .all(|row| row.relation_id.starts_with("physical-")));
    }
    let edges: Vec<_> = ids
        .iter()
        .flat_map(|id| {
            let p = restored.geometry.search(id).unwrap();
            let tile = restored
                .geometry
                .tile(Cell::at_point(16, p.x, p.y).unwrap(), Budget::default())
                .unwrap();
            let page = restored
                .geometry
                .tile_relations(&tile.selection, None, 256)
                .unwrap();
            for row in page.relations {
                let edge = tile
                    .edges
                    .iter()
                    .find(|edge| edge.id == row.rendered_edge_id)
                    .unwrap();
                let expected = if row.relation_id.starts_with("inferred-") {
                    TopologyClass::Inferred
                } else {
                    TopologyClass::Backbone
                };
                assert_eq!(
                    edge.topology_class, expected,
                    "selector crossed graph classes"
                );
            }
            tile.edges.into_iter()
        })
        .collect();
    assert!(edges.iter().any(|edge| edge.id == "physical-ra"
        && edge.topology_class == TopologyClass::Backbone
        && edge.count == 1));
    assert!(edges
        .iter()
        .all(|edge| edge.topology_class == TopologyClass::Backbone));
}

#[test]
fn stale_backbone_shortcut_stays_out_of_the_overview_and_the_packet_path() {
    let router = "sr:router.example.test";
    let access = "sr:access.example.test";
    let leaf = "sr:leaf.example.test";
    let ids = [router, access, leaf];
    let edges = vec![
        view_edge(
            "CANONICAL_TOPOLOGY",
            "physical-ra",
            (router, 1, "p1"),
            (access, 1, "p1"),
            "direct-physical",
            true,
        ),
        view_edge(
            "CANONICAL_TOPOLOGY",
            "physical-al",
            (access, 2, "p2"),
            (leaf, 1, "p1"),
            "direct-physical",
            true,
        ),
        view_edge(
            "CANONICAL_TOPOLOGY",
            "stale-ac",
            (router, 3, "p3"),
            (leaf, 2, "p2"),
            "direct-physical",
            true,
        )
        .with_stale(true),
    ];
    let view = TopologyView::new(
        ids.iter().map(|id| canonical_device(id, id)).collect(),
        edges,
    );
    let mut builder = Builder::new("synthetic-stale-forest".into(), 16).unwrap();
    builder
        .add_inventory(
            ids.iter()
                .enumerate()
                .map(|(index, id)| InventoryRow {
                    id: (*id).into(),
                    label: (*id).into(),
                    importance: if index == 0 { 0 } else { 1 },
                })
                .collect(),
        )
        .unwrap();
    let candidate = builder
        .reconcile(SourceGraph::from_view(view).unwrap())
        .unwrap();
    let placed = candidate
        .positions
        .iter()
        .find(|row| row.device_id == leaf)
        .unwrap();
    assert_eq!(placed.parent_id.as_deref(), Some(access));
    let stale = candidate
        .relations
        .iter()
        .find(|row| row.relation_id == "stale-ac")
        .unwrap();
    assert!(stale.stale);
    assert!(!stale.telemetry_eligible);
    assert!(candidate
        .relations
        .iter()
        .any(|row| row.relation_id == "physical-ra" && !row.stale && row.telemetry_eligible));
    let stats = &candidate.pipeline_stats;
    assert_eq!(stats.raw_links, 3);
    assert_eq!(stats.final_edges, 3);
    assert_eq!(stats.final_direct, 3);
    assert_eq!(stats.final_inferred, 0);
    assert_eq!(stats.edge_class_observed, None);
    let restored = {
        let mut cold = Builder::new("synthetic-stale-forest".into(), 16).unwrap();
        cold.add_positions(candidate.positions).unwrap();
        cold.add_relations(candidate.relations.to_vec()).unwrap();
        cold.finish().unwrap()
    };
    let detail = restored
        .geometry
        .detail(&DetailScope::Neighborhood(router.into()), None)
        .unwrap();
    assert!(detail.relations.iter().any(|row| row.id == "stale-ac"));
    for id in ids {
        for z in [0, 8, 16] {
            let point = restored.geometry.search(id).unwrap();
            let tile = restored
                .geometry
                .tile(
                    Cell::at_point(z, point.x, point.y).unwrap(),
                    Budget::default(),
                )
                .unwrap();
            let page = restored
                .geometry
                .tile_relations(&tile.selection, None, 256)
                .unwrap();
            assert!(page
                .relations
                .iter()
                .all(|row| row.relation_id != "stale-ac"));
            assert!(tile.edges.iter().all(|edge| !edge.stale));
        }
    }
}

#[test]
fn unknown_evidence_stays_out_of_backbone_publication_counts() {
    let left = "sr:unknown-left.example.test";
    let right = "sr:unknown-right.example.test";
    let view = TopologyView::new(
        vec![canonical_device(left, left), canonical_device(right, right)],
        vec![
            view_edge(
                "CANONICAL_TOPOLOGY",
                "missing-evidence",
                (left, 1, "p1"),
                (right, 1, "p1"),
                "",
                false,
            ),
            view_edge(
                "CANONICAL_TOPOLOGY",
                "unrecognized-evidence",
                (left, 2, "p2"),
                (right, 2, "p2"),
                "unrecognized",
                false,
            ),
        ],
    );
    let candidate = Builder::new("synthetic-unknown-evidence".into(), 16)
        .unwrap()
        .reconcile(SourceGraph::from_view(view).unwrap())
        .unwrap();

    assert_eq!(candidate.pipeline_stats.final_edges, 2);
    assert_eq!(candidate.pipeline_stats.edge_class_backbone, 0);
    assert_eq!(candidate.pipeline_stats.backbone_edge_count, 0);
    assert_eq!(candidate.pipeline_stats.edge_class_unknown, 2);
}

#[test]
fn logical_relations_are_not_reported_as_physical_backbone() {
    let left = "sr:logical-left.example.test";
    let right = "sr:logical-right.example.test";
    let mut logical = RelationRow::canonical(edge(left, right, 1, 0));
    logical.relation_id = "logical-only".into();
    logical.evidence_class = Some("direct-logical".into());
    let candidate = Builder::new("synthetic-logical-counts".into(), 16)
        .unwrap()
        .reconcile(SourceGraph {
            devices: BTreeMap::from([(left.into(), device(left)), (right.into(), device(right))]),
            relations: BTreeMap::from([(logical.relation_id.clone(), logical)]),
            raw_links: 1,
        })
        .unwrap();

    assert_eq!(candidate.pipeline_stats.edge_class_backbone, 0);
    assert_eq!(candidate.pipeline_stats.backbone_edge_count, 0);
    assert_eq!(candidate.pipeline_stats.edge_class_logical, 1);
}

#[test]
fn aged_attachment_and_hosted_links_stay_connected() {
    let router = "sr:router.example.test";
    let access = "sr:access.example.test";
    let peer = "sr:peer.example.test";
    let leaf = "sr:leaf.example.test";
    let guest = "sr:guest.example.test";
    let ids = [router, access, peer, leaf, guest];
    let attach_stale = view_edge(
        "ATTACHED_TO",
        "attach-stale",
        (router, 2, "p2"),
        (access, 2, "p2"),
        "direct-physical",
        true,
    )
    .with_stale(true)
    .with_last_seen("2020-01-01T00:00:00Z");
    let stale_key = attach_stale.edge().link_key().to_owned();
    let edges = vec![
        view_edge(
            "ATTACHED_TO",
            "attach-fresh",
            (router, 1, "p1"),
            (access, 1, "p1"),
            "direct-physical",
            true,
        )
        .with_last_seen("2024-02-01T00:00:00Z"),
        attach_stale,
        view_edge(
            "ATTACHED_TO",
            "attach-al",
            (access, 3, "p3"),
            (leaf, 1, "p1"),
            "direct-physical",
            true,
        )
        .with_last_seen("2024-02-01T00:00:00Z"),
        view_edge(
            "ATTACHED_TO",
            "attach-peer-leaf",
            (peer, 1, "p1"),
            (leaf, 3, "p3"),
            "direct-physical",
            true,
        )
        .with_last_seen("2024-02-01T00:00:00Z"),
        view_edge(
            "ATTACHED_TO",
            "attach-shortcut",
            (router, 4, "p4"),
            (leaf, 2, "p2"),
            "direct-physical",
            true,
        )
        .with_stale(true)
        .with_last_seen("2019-01-01T00:00:00Z"),
        view_edge(
            "CANONICAL_TOPOLOGY",
            "backbone-shortcut",
            (router, 6, "p6"),
            (leaf, 4, "p4"),
            "direct-physical",
            true,
        )
        .with_stale(true)
        .with_last_seen("2018-01-01T00:00:00Z"),
        view_edge(
            "HOSTED_ON",
            "hosted-guest",
            (access, 5, "p5"),
            (guest, 1, "p1"),
            "hosted-virtual",
            true,
        )
        .with_last_seen("2024-03-01T00:00:00Z"),
    ];
    let devices: Vec<_> = ids.iter().map(|id| canonical_device(id, id)).collect();
    let mut builder = Builder::new("synthetic-aged-attachment".into(), 16).unwrap();
    builder
        .add_inventory(
            ids.iter()
                .enumerate()
                .map(|(index, id)| InventoryRow {
                    id: (*id).into(),
                    label: (*id).into(),
                    importance: if index == 0 { 0 } else { 1 },
                })
                .collect(),
        )
        .unwrap();
    let candidate = builder
        .reconcile(
            SourceGraph::from_view(TopologyView::new(devices.clone(), edges.clone())).unwrap(),
        )
        .unwrap();
    let row = |id: &str| {
        candidate
            .relations
            .iter()
            .find(|row| row.relation_id == id)
            .unwrap_or_else(|| panic!("missing {id}"))
    };
    let aged = row("attach-stale");
    assert!(aged.stale);
    assert!(!aged.telemetry_eligible);
    assert_eq!(aged.last_seen.as_deref(), Some("2020-01-01T00:00:00Z"));
    let fresh = row("attach-fresh");
    assert!(!fresh.stale);
    assert!(!fresh.telemetry_eligible);
    assert_eq!(fresh.last_seen.as_deref(), Some("2024-02-01T00:00:00Z"));
    let hosted = row("hosted-guest");
    assert!(!hosted.stale);
    assert!(!hosted.telemetry_eligible);
    assert_eq!(hosted.last_seen.as_deref(), Some("2024-03-01T00:00:00Z"));
    assert!(row("attach-shortcut").stale);
    assert_eq!(
        candidate
            .positions
            .iter()
            .find(|row| row.device_id == leaf)
            .unwrap()
            .parent_id
            .as_deref(),
        Some(access)
    );
    assert!(candidate
        .relations
        .iter()
        .any(|row| row.relation_id == "backbone-shortcut" && row.stale));
    assert!(candidate
        .relations
        .iter()
        .any(|row| row.relation_id == "attach-peer-leaf" && !row.stale));
    assert!(candidate.positions.iter().any(|row| row.device_id == guest));
    let geometry = &candidate.world.geometry;
    let detail = geometry
        .detail(&DetailScope::Neighborhood(router.into()), None)
        .unwrap();
    assert!(detail
        .relations
        .iter()
        .any(|row| row.id == "attach-shortcut"));
    assert!(detail
        .relations
        .iter()
        .any(|row| row.id == "backbone-shortcut"));
    let mut split = false;
    for z in [0_u8, 8, 16] {
        let point = geometry.search(router).unwrap();
        let tile = geometry
            .tile(
                Cell::at_point(z, point.x, point.y).unwrap(),
                Budget::default(),
            )
            .unwrap();
        let members = |id: &str| {
            tile.edges.iter().find(|edge| {
                let page = geometry
                    .bundle_detail(&tile.selection, &edge.id, None)
                    .unwrap();
                let ids: BTreeSet<_> = page.relations.iter().map(|row| row.id.as_str()).collect();
                assert!(
                    !(ids.contains("attach-fresh") && ids.contains("attach-stale")),
                    "bundle {} mixed current and stale attachments",
                    edge.id
                );
                assert!(!ids.contains("attach-shortcut"));
                assert!(!ids.contains("backbone-shortcut"));
                ids.contains(id)
            })
        };
        if let (Some(current), Some(known)) = (members("attach-fresh"), members("attach-stale")) {
            assert_ne!(current.id, known.id);
            assert_eq!(current.topology_class, known.topology_class);
            assert_eq!(current.topology_class, TopologyClass::Endpoints);
            assert!(!current.stale);
            assert!(known.stale);
            assert_eq!(
                (current.source, current.target),
                (known.source, known.target)
            );
            let only = |edge_id: &str, relation_id: &str| {
                let page = geometry
                    .bundle_detail(&tile.selection, edge_id, None)
                    .unwrap();
                assert_eq!(
                    page.relations
                        .iter()
                        .map(|row| row.id.as_str())
                        .collect::<Vec<_>>(),
                    vec![relation_id]
                );
            };
            only(&current.id, "attach-fresh");
            only(&known.id, "attach-stale");
            split = true;
        }
    }
    assert!(split);
    let restored = {
        let mut cold = Builder::new("synthetic-aged-attachment".into(), 16).unwrap();
        cold.add_positions(candidate.positions.clone()).unwrap();
        cold.add_relations(candidate.relations.to_vec()).unwrap();
        cold.finish().unwrap()
    };
    let stored = restored
        .relations
        .iter()
        .find(|row| row.relation_id == "attach-stale")
        .unwrap();
    assert!(stored.stale);
    assert_eq!(stored.last_seen.as_deref(), Some("2020-01-01T00:00:00Z"));
    let refreshed = edges
        .into_iter()
        .map(|edge| {
            if edge.edge().link_key() == stale_key {
                edge.with_stale(false)
                    .with_last_seen("2024-06-01T00:00:00Z")
            } else {
                edge
            }
        })
        .collect();
    let mut next = Builder::new("synthetic-aged-attachment".into(), 16).unwrap();
    next.add_inventory(
        ids.iter()
            .enumerate()
            .map(|(index, id)| InventoryRow {
                id: (*id).into(),
                label: (*id).into(),
                importance: if index == 0 { 0 } else { 1 },
            })
            .collect(),
    )
    .unwrap();
    next.add_positions(candidate.positions).unwrap();
    next.add_relations(candidate.relations.to_vec()).unwrap();
    let again = next
        .reconcile(SourceGraph::from_view(TopologyView::new(devices, refreshed)).unwrap())
        .unwrap();
    let current = again
        .relations
        .iter()
        .find(|row| row.relation_id == "attach-stale")
        .unwrap();
    assert!(!current.stale);
    assert_eq!(current.last_seen.as_deref(), Some("2024-06-01T00:00:00Z"));
}

fn stamp(mut row: RelationRow, last_seen: Option<&str>) -> RelationRow {
    row.last_seen = last_seen.map(str::to_owned);
    row
}

fn placed(id: &str, x: u32, y: u32) -> PositionRow {
    PositionRow {
        device_id: id.into(),
        label: "Synthetic device".into(),
        x,
        y,
        min_zoom: 0,
        parent_id: None,
        component_id: "synthetic-component".into(),
        component_z: 0,
        component_x: 0,
        component_y: 0,
        placement_depth: 4,
        active: true,
    }
}

#[test]
fn bundle_observation_time_is_shared_across_members() {
    let a = "sr:seen-a.example.test";
    let b = "sr:seen-b.example.test";
    let c = "sr:seen-c.example.test";
    let d = "sr:seen-d.example.test";
    let e = "sr:seen-e.example.test";
    let mut builder = Builder::new("synthetic-observation".into(), 16).unwrap();
    builder
        .add_positions(vec![
            placed(a, 100, 100),
            placed(b, 8_000_000, 100),
            placed(c, 100, 8_000_000),
            placed(d, 8_000_000, 8_000_000),
            placed(e, 4_000_000, 4_000_000),
        ])
        .unwrap();
    builder
        .add_relations(vec![
            stamp(
                physical("invented-shared-1", a, b, 1, "p1", 1, "p1"),
                Some("2020-01-01T00:00:00Z"),
            ),
            stamp(
                physical("invented-shared-2", a, b, 2, "p2", 2, "p2"),
                Some("2020-01-01T00:00:00Z"),
            ),
            stamp(
                physical("invented-mixed-1", b, c, 1, "p1", 1, "p1"),
                Some("2020-01-01T00:00:00Z"),
            ),
            stamp(
                physical("invented-mixed-2", b, c, 2, "p2", 2, "p2"),
                Some("2024-02-01T00:00:00Z"),
            ),
            stamp(
                physical("invented-single", c, d, 1, "p1", 1, "p1"),
                Some("2024-06-01T00:00:00Z"),
            ),
            stamp(
                physical("invented-blank-1", d, e, 1, "p1", 1, "p1"),
                Some(""),
            ),
            stamp(physical("invented-blank-2", d, e, 2, "p2", 2, "p2"), None),
        ])
        .unwrap();
    let world = builder.finish().unwrap();
    let tile = world
        .geometry
        .tile(Cell::new(0, 0, 0).unwrap(), Budget::default())
        .unwrap();
    let mut observed = BTreeMap::new();
    for edge in &tile.edges {
        let info = world
            .geometry
            .bundle_info(&tile.selection, &edge.id)
            .unwrap();
        let page = world
            .geometry
            .bundle_detail(&tile.selection, &edge.id, None)
            .unwrap();
        let ids: BTreeSet<_> = page.relations.iter().map(|row| row.id.clone()).collect();
        assert_eq!(ids.len() as u64, page.total_relations);
        observed.insert(ids, info.last_seen);
    }
    let members = |ids: &[&str]| {
        ids.iter()
            .map(|id| (*id).to_owned())
            .collect::<BTreeSet<_>>()
    };
    assert_eq!(
        observed[&members(&["invented-shared-1", "invented-shared-2"])].as_deref(),
        Some("2020-01-01T00:00:00Z")
    );
    assert_eq!(
        observed[&members(&["invented-mixed-1", "invented-mixed-2"])],
        None
    );
    assert_eq!(
        observed[&members(&["invented-single"])].as_deref(),
        Some("2024-06-01T00:00:00Z")
    );
    assert_eq!(
        observed[&members(&["invented-blank-1", "invented-blank-2"])],
        None
    );
}

#[test]
fn black_holed_graph_read_times_out_within_its_deadline() {
    // Completes the TCP handshake from its backlog, never answers.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!(
        "dgraph://127.0.0.1:{}",
        listener.local_addr().unwrap().port()
    );
    let started = std::time::Instant::now();
    let (result, kind) = crate::runtime()
        .unwrap()
        .block_on(crate::async_read::read_topology_view(
            &url,
            "2026-01-01T00:00:00Z",
            std::time::Duration::from_millis(300),
        ));
    assert_eq!(kind, crate::async_read::Kind::Timeout);
    assert!(matches!(result, Err(reason) if reason.contains("timed out")));
    assert!(started.elapsed() < std::time::Duration::from_secs(5));
    drop(listener);
}

#[test]
fn an_async_read_permit_is_released_when_dropped() {
    static GATE: crate::admission::Gate = crate::admission::Gate::new(1);
    let permit = GATE.try_acquire().expect("first permit");
    assert!(GATE.try_acquire().is_none(), "the gate must be full");
    drop(permit);
    assert!(GATE.try_acquire().is_some());
}
