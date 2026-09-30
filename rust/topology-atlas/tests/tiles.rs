use std::collections::BTreeSet;

use serviceradar_topology_atlas::{
    Budget, Cell, DetailScope, Error, GlyphKind, Position, Relation, RelationCursor, TileProfile,
    WORLD_EXTENT, World,
};

fn position(i: u32, x: u32, y: u32, min_zoom: u8) -> Position {
    Position {
        id: format!("sr:node-{i:04}.example.test"),
        label: format!("node-{i:04}.example.test"),
        x,
        y,
        min_zoom,
        parent_id: None,
        component_id: "sr:component.example.test".into(),
        component: Cell::new(0, 0, 0).unwrap(),
        placement_depth: 24,
    }
}

fn edge(a: &Position, b: &Position) -> Relation {
    Relation {
        id: format!("{}/{}", a.id, b.id),
        source: a.id.clone(),
        target: b.id.clone(),
    }
}

#[test]
fn aggregate_profile_bounds_identity_bytes_without_losing_singletons_or_clipped_flow() {
    let mut points = vec![
        position(1, 1, 5_000_000, 0),
        position(2, 16_000_000, 5_000_000, 0),
    ];
    for point in &mut points {
        point.id.push_str(&"x".repeat(1800));
    }
    let mut relation = edge(&points[0], &points[1]);
    // Deliberately oversized invented identity exercises the descriptor budget
    // before serialization, independently of the Arrow encoder's wire-byte test.
    relation.id = "synthetic-relation-".to_owned() + &"r".repeat(1_100_000);
    let world = World::new(
        "compact-identities".into(),
        16,
        points.clone(),
        vec![relation.clone()],
    )
    .unwrap();
    let root = Cell::new(0, 0, 0).unwrap();
    assert!(matches!(
        world.tile(root, Budget::default()),
        Err(Error::SelectionBudgetExceeded)
    ));
    assert!(matches!(
        world.tile_with_profile(
            root,
            Budget {
                nodes: 8,
                edges: 72
            },
            TileProfile::AggregateOnly
        ),
        Err(Error::InvalidBudget)
    ));
    let compact = world
        .tile_with_profile(root, Budget::default(), TileProfile::AggregateOnly)
        .unwrap();
    assert_eq!(compact.profile, TileProfile::AggregateOnly);
    assert_eq!(compact.selection.profile(), TileProfile::AggregateOnly);
    assert_eq!(compact.device_count, 2);
    assert_eq!(compact.glyphs.len(), 2);
    assert!(compact.glyphs.iter().all(|g| g.kind == GlyphKind::Aggregate
        && g.count == 1
        && g.id.len() < 256
        && g.label.len() < 32));
    assert_eq!(compact.edges.len(), 1);
    assert_eq!(compact.edges[0].count, 1);
    assert!(compact.edges[0].id.len() < 128);
    assert!(compact.selection.retained_bytes() < 4096);
    let mut members = BTreeSet::new();
    for glyph in &compact.glyphs {
        let selection = world
            .aggregate_selection(&compact.selection, &glyph.id)
            .unwrap();
        let page = world
            .detail(&DetailScope::AggregateMembers(selection), None)
            .unwrap();
        assert_eq!(page.total_members, 1);
        members.insert(page.nodes[0].id.clone());
    }
    assert_eq!(members, points.iter().map(|p| p.id.clone()).collect());
    let selected = world.tile_relations(&compact.selection, None, 256).unwrap();
    assert_eq!(selected.total_rendered_relations, 1);
    assert_eq!(selected.relations[0].relation_id, relation.id);
    assert_eq!(selected.relations[0].rendered_edge_id, compact.edges[0].id);
    assert_eq!(selected.relations[0].bundle_members, 1);

    // Replacing a singleton's canonical identity changes membership, but the
    // compact geometry and stable rendered bundle identity remain unchanged.
    relation.id = "replacement-synthetic-relation".into();
    let changed = World::new("compact-identities".into(), 16, points, vec![relation]).unwrap();
    let replacement = changed
        .tile_with_profile(root, Budget::default(), TileProfile::AggregateOnly)
        .unwrap();
    assert_eq!(compact.revision, replacement.revision);
    let standard = changed.tile(root, Budget::default()).unwrap();
    assert_eq!(standard.profile, TileProfile::Standard);
    assert!(standard.glyphs.iter().all(|g| g.kind == GlyphKind::Device));
    assert_ne!(standard.revision, replacement.revision);
    let cursor = RelationCursor {
        world_revision: changed.detail_revision().into(),
        tile_revision: standard.revision,
        offset: 0,
    };
    assert_eq!(
        changed.tile_relations(&replacement.selection, Some(&cursor), 1),
        Err(Error::InvalidDetailCursor)
    );

    let left_cell = Cell::new(2, 1, 1).unwrap();
    let right_cell = Cell::new(2, 2, 1).unwrap();
    let left = changed
        .tile_with_profile(left_cell, Budget::default(), TileProfile::AggregateOnly)
        .unwrap();
    let right = changed
        .tile_with_profile(right_cell, Budget::default(), TileProfile::AggregateOnly)
        .unwrap();
    assert_eq!(left.device_count + right.device_count, 0);
    assert_eq!(left.edges[0].end, right.edges[0].start);
    assert!(left.edges[0].start < left.edges[0].end && right.edges[0].start < right.edges[0].end);
    let left_portal = &left.glyphs[left.edges[0].target as usize];
    let right_portal = &right.glyphs[right.edges[0].source as usize];
    assert_eq!(
        (&left_portal.id, left_portal.x, left_portal.y),
        (&right_portal.id, right_portal.x, right_portal.y)
    );
    let original_phase = changed.tile(left_cell, Budget::default()).unwrap();
    assert_eq!(
        (left.edges[0].start, left.edges[0].end),
        (original_phase.edges[0].start, original_phase.edges[0].end)
    );
}

#[test]
fn every_zoom_conserves_members_under_dense_fanout_budgets() {
    let points: Vec<_> = (0..96)
        .map(|i| {
            position(
                i,
                1 + i * 167_923,
                1 + ((i * 37) % 96) * 167_923,
                if i < 4 {
                    0
                } else if i < 16 {
                    4
                } else {
                    8
                },
            )
        })
        .collect();
    let mut edges = Vec::new();
    for a in &points {
        for b in &points {
            if a.id != b.id {
                edges.push(edge(a, b));
            }
        }
    }
    let budget = Budget {
        nodes: 12,
        edges: 72,
    };
    let world = World::new("layout-synthetic".into(), 16, points.clone(), edges.clone()).unwrap();
    let reversed = World::new(
        "layout-synthetic".into(),
        16,
        points.iter().cloned().rev().collect(),
        edges.into_iter().rev().collect(),
    )
    .unwrap();
    for z in 0..=16 {
        let cells: BTreeSet<_> = points
            .iter()
            .map(|p| Cell::at_point(z, p.x, p.y).unwrap())
            .collect();
        let mut count = 0;
        for cell in cells {
            let tile = world.tile(cell, budget).unwrap();
            assert!(tile.glyphs.len() <= budget.nodes && tile.edges.len() <= budget.edges);
            assert_eq!(
                tile.device_count,
                tile.glyphs.iter().map(|g| g.count).sum::<u64>()
            );
            let expected = points.iter().filter(|p| cell.contains(p.x, p.y)).count() as u64;
            assert_eq!(tile.device_count, expected, "tile {cell:?}");
            count += tile.device_count;
            for glyph in &tile.glyphs {
                if glyph.kind == GlyphKind::Device {
                    let p = points.iter().find(|p| p.id == glyph.id).unwrap();
                    assert_eq!((glyph.x, glyph.y), (f64::from(p.x), f64::from(p.y)));
                } else if glyph.kind == GlyphKind::Boundary {
                    assert_eq!(glyph.count, 0);
                }
            }
            assert_eq!(tile.revision, reversed.tile(cell, budget).unwrap().revision);
        }
        assert_eq!(count, points.len() as u64, "zoom {z}");
    }
}

#[test]
fn crossing_segments_survive_without_endpoints_and_share_exact_boundaries() {
    let points = vec![
        position(1, 1, 5_000_000, 0),
        position(2, 16_000_000, 5_000_000, 0),
    ];
    let relations = vec![edge(&points[0], &points[1])];
    let world = World::new("crossing".into(), 4, points, relations.clone()).unwrap();
    let left = world
        .tile(Cell::new(2, 1, 1).unwrap(), Budget::default())
        .unwrap();
    let right = world
        .tile(Cell::new(2, 2, 1).unwrap(), Budget::default())
        .unwrap();
    for tile in [&left, &right] {
        assert_eq!(tile.device_count, 0);
        assert_eq!(tile.glyphs.len(), 2);
        assert_eq!(tile.edges.len(), 1);
        assert_eq!(tile.edges[0].id, relations[0].id);
        assert!(
            tile.glyphs
                .iter()
                .all(|g| g.kind == GlyphKind::Boundary && g.count == 0)
        );
    }
    let a = &left.glyphs[left.edges[0].target as usize];
    let b = &right.glyphs[right.edges[0].source as usize];
    assert_eq!((a.x, a.y), (8_388_608.0, 6_291_456.0));
    assert_eq!((a.x, a.y), (b.x, b.y));
    assert_eq!(left.edges[0].end, right.edges[0].start);
    let outside = world
        .tile(Cell::new(2, 1, 0).unwrap(), Budget::default())
        .unwrap();
    assert!(outside.edges.is_empty() && outside.glyphs.is_empty());
}

#[test]
fn geometry_revisions_change_only_where_displayed_content_changes() {
    let mut points = vec![
        position(1, 10, 10, 0),
        position(2, WORLD_EXTENT - 10, WORLD_EXTENT - 10, 0),
    ];
    let before = World::new("revision".into(), 16, points.clone(), vec![]).unwrap();
    points[0].label = "renamed.example.test".into();
    let after = World::new("revision".into(), 16, points.clone(), vec![]).unwrap();
    for z in 1..=16 {
        let changed = Cell::at_point(z, points[0].x, points[0].y).unwrap();
        let unchanged = Cell::at_point(z, points[1].x, points[1].y).unwrap();
        assert_ne!(
            before.tile(changed, Budget::default()).unwrap().revision,
            after.tile(changed, Budget::default()).unwrap().revision
        );
        assert_eq!(
            before.tile(unchanged, Budget::default()).unwrap().revision,
            after.tile(unchanged, Budget::default()).unwrap().revision
        );
    }
    assert_eq!(after.search(&points[0].id), Some(&points[0]));
    assert!(after.search("sr:absent.example.test").is_none());
}

#[test]
fn corners_and_owned_boundary_contacts_preserve_adjacency_and_flow_phase() {
    let a = position(1, 1, 1, 0);
    let b = position(2, WORLD_EXTENT - 1, WORLD_EXTENT - 1, 0);
    let world = World::new(
        "corners".into(),
        4,
        vec![a.clone(), b.clone()],
        vec![edge(&a, &b)],
    )
    .unwrap();
    let before = world
        .tile(Cell::new(1, 0, 0).unwrap(), Budget::default())
        .unwrap();
    let after = world
        .tile(Cell::new(1, 1, 1).unwrap(), Budget::default())
        .unwrap();
    let exit = &before.glyphs[before.edges[0].target as usize];
    let entry = &after.glyphs[after.edges[0].source as usize];
    assert_eq!((exit.x, exit.y), (8_388_608.0, 8_388_608.0));
    assert_eq!(exit.id, entry.id);
    assert_eq!(before.edges[0].end, after.edges[0].start);
    for cell in [Cell::new(1, 0, 1).unwrap(), Cell::new(1, 1, 0).unwrap()] {
        let tangent = world.tile(cell, Budget::default()).unwrap();
        assert!(tangent.glyphs.is_empty() && tangent.edges.is_empty());
    }

    for (y, minimum_zoom, kind, profile) in [
        (5_000_000, 0, GlyphKind::Device, TileProfile::Standard),
        (
            WORLD_EXTENT / 4,
            8,
            GlyphKind::Aggregate,
            TileProfile::AggregateOnly,
        ),
        (
            WORLD_EXTENT / 4,
            8,
            GlyphKind::Device,
            TileProfile::Standard,
        ),
    ] {
        let a = position(3, WORLD_EXTENT / 2, y, minimum_zoom);
        let b = position(4, 1, y, 0);
        let world = World::new(
            "contacts".into(),
            4,
            vec![a.clone(), b.clone()],
            vec![edge(&a, &b), edge(&a, &a)],
        )
        .unwrap();
        let owner = world
            .tile_with_profile(Cell::new(1, 1, 0).unwrap(), Budget::default(), profile)
            .unwrap();
        let neighbor = world
            .tile_with_profile(Cell::new(1, 0, 0).unwrap(), Budget::default(), profile)
            .unwrap();
        assert_eq!(owner.internal_relations, 1);
        assert_eq!(owner.device_count, 1);
        let continuation = &neighbor.edges[0];
        if y == WORLD_EXTENT / 4 && kind == GlyphKind::Device {
            // A zero-length rendered connector is omitted, not counted as an
            // additional internal relation. Its reserved phase stays stable.
            assert!(owner.edges.is_empty());
            assert!(continuation.start > 0.0);
            continue;
        }
        assert_eq!(owner.edges.len(), 1);
        let closure = &owner.edges[0];
        assert_eq!(owner.glyphs[closure.source as usize].kind, kind);
        assert_eq!(
            owner.glyphs[closure.target as usize].id,
            neighbor.glyphs[continuation.source as usize].id
        );
        assert_eq!(closure.start, 0.0);
        assert!(closure.end > 0.0 && closure.end < 1.0);
        assert_eq!(closure.end, continuation.start);
        assert_eq!(continuation.end, 1.0);
    }
}

#[test]
fn bundle_identity_survives_unrelated_row_insertions() {
    let a = position(1, 500, 500, 0);
    let b = position(2, 900, 900, 0);
    let first = edge(&a, &b);
    let mut second = first.clone();
    second.id.push_str("/redundant");
    let relations = vec![first, second];
    let before = World::new(
        "bundle".into(),
        4,
        vec![a.clone(), b.clone()],
        relations.clone(),
    )
    .unwrap();
    let after = World::new(
        "bundle".into(),
        4,
        vec![position(3, 1, 1, 0), a, b],
        relations,
    )
    .unwrap();
    let root = Cell::new(0, 0, 0).unwrap();
    let original = before.tile(root, Budget::default()).unwrap();
    let inserted = after.tile(root, Budget::default()).unwrap();
    assert_eq!(original.edges[0].count, 2);
    assert_eq!(original.edges[0].id, inserted.edges[0].id);
    assert_ne!(original.edges[0].source, inserted.edges[0].source);
}
