//! Invented topology only. Public engine contracts own selection/paging proof;
//! NIF and HTTP tests separately own transport and authorization boundaries.

use std::collections::{BTreeMap, BTreeSet};

use serviceradar_topology_atlas::{
    Budget, Cell, DETAIL_EDGE_LIMIT, DETAIL_MEMBER_LIMIT, DETAIL_NODE_LIMIT, DetailCursor,
    DetailScope, Error, GlyphKind, MAX_SELECTION_BYTES, Position, RELATION_CANDIDATE_LIMIT,
    Relation, TileProfile, World,
};

fn point(index: u32, x: u32, y: u32, min_zoom: u8) -> Position {
    Position {
        id: format!("sr:host{index:06}.example.com"),
        label: format!("host{index:06}.example.com"),
        x,
        y,
        min_zoom,
        parent_id: None,
        component_id: "component:SITE01".into(),
        component: Cell::new(0, 0, 0).unwrap(),
        placement_depth: 24,
    }
}

fn relation(id: String, source: &Position, target: &Position) -> Relation {
    Relation {
        id,
        source: source.id.clone(),
        target: target.id.clone(),
    }
}

#[test]
fn giant_neighborhood_and_parallel_links_remain_reachable_in_bounded_pages() {
    const PEERS: u32 = 65_537;
    const PARALLEL: u32 = 769;
    let nodes: Vec<_> = (0..=PEERS + 1).map(|i| point(i, i + 1, 1, 0)).collect();
    let mut relations: Vec<_> = (1..=PEERS)
        .map(|i| relation(format!("access-{i:06}"), &nodes[0], &nodes[i as usize]))
        .collect();
    relations
        .extend((0..PARALLEL).map(|i| relation(format!("parallel-{i:04}"), &nodes[1], &nodes[0])));
    let expected: BTreeSet<_> = relations.iter().map(|r| r.id.clone()).collect();
    let world = World::new("invented-detail".into(), 16, nodes.clone(), relations).unwrap();
    let scope = DetailScope::Neighborhood(nodes[0].id.clone());
    let mut cursor = None;
    let mut seen = BTreeSet::new();
    let mut members = BTreeSet::new();
    let mut pages = 0;
    loop {
        let page = world.detail(&scope, cursor.as_ref()).unwrap();
        pages += 1;
        assert!(pages < 1000, "pagination must terminate");
        assert!(page.nodes.len() <= DETAIL_NODE_LIMIT);
        assert!(page.relations.len() <= DETAIL_EDGE_LIMIT);
        assert_eq!(page.total_members, u64::from(PEERS));
        assert_eq!(page.incident_relations, Some(u64::from(PEERS + PARALLEL)));
        assert_eq!(page.nodes[0].id, nodes[0].id);
        members.extend(page.nodes.iter().skip(1).map(|n| n.id.clone()));
        for row in page.relations {
            assert!(seen.insert(row.id.clone()), "relation repeated: {}", row.id);
            let source = &page.nodes[row.source as usize].id;
            let target = &page.nodes[row.target as usize].id;
            if row.id.starts_with("parallel-") {
                assert_eq!((source, target), (&nodes[1].id, &nodes[0].id));
            } else {
                assert_eq!(source, &nodes[0].id);
                assert_ne!(source, target);
            }
        }
        cursor = page.next;
        if cursor.is_none() {
            break;
        }
    }
    assert_eq!(seen, expected);
    assert_eq!(members.len(), PEERS as usize);
    let isolated = world
        .detail(
            &DetailScope::Neighborhood(nodes[(PEERS + 1) as usize].id.clone()),
            None,
        )
        .unwrap();
    assert_eq!(isolated.nodes.len(), 1);
    assert_eq!(isolated.total_members, 0);
    assert_eq!(isolated.incident_relations, Some(0));
    assert!(isolated.relations.is_empty() && isolated.next.is_none());
}

#[test]
fn aggregate_pages_exclude_promoted_devices_and_conserve_clicked_counts() {
    let nodes: Vec<_> = (0..1025)
        .map(|i| point(i, i + 1, 1, if i == 300 { 0 } else { 8 }))
        .collect();
    let world = World::new("invented-aggregate".into(), 16, nodes.clone(), vec![]).unwrap();
    let tile = world
        .tile(
            Cell::new(0, 0, 0).unwrap(),
            Budget {
                nodes: 9,
                edges: 72,
            },
        )
        .unwrap();
    let promoted: BTreeSet<_> = tile
        .glyphs
        .iter()
        .filter(|g| g.kind == GlyphKind::Device)
        .map(|g| g.id.clone())
        .collect();
    assert_eq!(promoted, BTreeSet::from([nodes[300].id.clone()]));
    assert!(tile.selection.retained_bytes() <= MAX_SELECTION_BYTES);
    let mut all_members = BTreeSet::new();
    let mut multiple_pages = false;
    for glyph in tile
        .glyphs
        .iter()
        .filter(|g| g.kind == GlyphKind::Aggregate)
    {
        let selected = world
            .aggregate_selection(&tile.selection, &glyph.id)
            .unwrap();
        assert_eq!(selected.member_count() as u64, glyph.count);
        let scope = DetailScope::AggregateMembers(selected);
        let mut cursor = None;
        let mut seen = BTreeSet::new();
        loop {
            let page = world.detail(&scope, cursor.as_ref()).unwrap();
            assert_eq!(page.total_members, glyph.count);
            assert!(page.nodes.len() <= DETAIL_MEMBER_LIMIT);
            for node in page.nodes {
                assert!(!promoted.contains(&node.id));
                assert!(seen.insert(node.id.clone()));
                assert!(all_members.insert(node.id));
            }
            cursor = page.next;
            multiple_pages |= cursor.is_some();
            if cursor.is_none() {
                break;
            }
        }
        assert_eq!(seen.len() as u64, glyph.count);
    }
    assert!(multiple_pages);
    all_members.extend(promoted);
    assert_eq!(all_members, nodes.iter().map(|n| n.id.clone()).collect());
    assert_eq!(
        world.aggregate_selection(&tile.selection, &nodes[300].id),
        Err(Error::DetailNotFound)
    );
}

#[test]
fn cursors_pin_membership_and_scope_and_preserve_self_loops_once() {
    let nodes: Vec<_> = (0..130).map(|i| point(i, i + 1, 1, 0)).collect();
    let relations = vec![relation("self".into(), &nodes[0], &nodes[0])];
    let world = World::new(
        "invented-cursors".into(),
        16,
        nodes.clone(),
        relations.clone(),
    )
    .unwrap();
    let scope = DetailScope::ComponentMembers(nodes[0].component_id.clone());
    let first = world.detail(&scope, None).unwrap();
    assert_eq!(first.nodes.len(), DETAIL_MEMBER_LIMIT);
    assert_eq!(first.total_members, 130);
    assert_eq!(first.selected_relations, 1);
    assert_eq!(first.relations[0].source, first.relations[0].target);
    let cursor = first.next.unwrap();
    assert_eq!(
        world.detail(
            &DetailScope::Neighborhood(nodes[0].id.clone()),
            Some(&cursor)
        ),
        Err(Error::InvalidDetailCursor)
    );
    let mut changed = nodes.clone();
    changed[100].label = "updated.example.com".into();
    let next_world = World::new("invented-cursors".into(), 16, changed, relations.clone()).unwrap();
    assert_eq!(
        next_world.detail(&scope, Some(&cursor)),
        Err(Error::StaleDetailRevision)
    );
    let invalid = DetailCursor {
        node_page: u32::MAX,
        ..cursor.clone()
    };
    assert!(matches!(
        world.detail(&scope, Some(&invalid)),
        Err(Error::DetailNotFound | Error::InvalidDetailCursor)
    ));
    let invalid = DetailCursor {
        edge_page: u32::MAX,
        ..cursor.clone()
    };
    assert!(matches!(
        world.detail(&scope, Some(&invalid)),
        Err(Error::DetailNotFound | Error::InvalidDetailCursor)
    ));
    let reordered = World::new(
        "invented-cursors".into(),
        16,
        nodes.into_iter().rev().collect(),
        relations,
    )
    .unwrap();
    assert_eq!(
        world.detail(&scope, Some(&cursor)),
        reordered.detail(&scope, Some(&cursor))
    );
    let mut ids: BTreeSet<_> = first.nodes.into_iter().map(|n| n.id).collect();
    let mut next = Some(cursor);
    while let Some(cursor) = next {
        let page = world.detail(&scope, Some(&cursor)).unwrap();
        ids.extend(page.nodes.into_iter().map(|n| n.id));
        next = page.next;
    }
    assert_eq!(ids.len(), 130);
}

#[test]
fn clipped_bundle_selection_preserves_ids_direction_and_exact_coverage() {
    let nodes = vec![
        point(0, 1, 5_000_000, 0),
        point(1, 16_000_000, 5_000_000, 0),
    ];
    let relations: Vec<_> = (0..513)
        .map(|i| {
            let (source, target) = if i < 321 {
                (&nodes[0], &nodes[1])
            } else {
                (&nodes[1], &nodes[0])
            };
            relation(format!("relation-{i:04}"), source, target)
        })
        .collect();
    let expected: BTreeSet<_> = relations.iter().map(|r| r.id.clone()).collect();
    let world = World::new(
        "invented-clipped".into(),
        16,
        nodes.clone(),
        relations.clone(),
    )
    .unwrap();
    let tile = world
        .tile(Cell::new(2, 1, 1).unwrap(), Budget::default())
        .unwrap();
    assert_eq!(tile.device_count, 0);
    assert_eq!(tile.edges.len(), 2);
    let rendered: BTreeMap<_, _> = tile.edges.iter().map(|e| (e.id.as_str(), e)).collect();
    let mut cursor = None;
    let mut seen = BTreeSet::new();
    let mut first_cursor = None;
    loop {
        let page = world
            .tile_relations(&tile.selection, cursor.as_ref(), 256)
            .unwrap();
        assert_eq!(page.total_rendered_relations, 513);
        assert!(page.relations.len() <= 256 && page.candidates <= RELATION_CANDIDATE_LIMIT);
        for row in page.relations {
            assert!(seen.insert(row.relation_id.clone()));
            assert_eq!(row.relation_id, relations[row.relation_index as usize].id);
            let edge = rendered[row.rendered_edge_id.as_str()];
            assert_eq!(
                (row.source_glyph, row.target_glyph),
                (edge.source, edge.target)
            );
            assert!(!row.reversed);
            let increasing =
                tile.glyphs[row.source_glyph as usize].x < tile.glyphs[row.target_glyph as usize].x;
            assert_eq!(increasing, row.relation_index < 321);
            assert_eq!(row.bundle_members, if increasing { 321 } else { 192 });
        }
        cursor = page.next;
        first_cursor = first_cursor.or_else(|| cursor.clone());
        if cursor.is_none() {
            break;
        }
    }
    assert_eq!(seen, expected);
    let mut bundle_cursor = None;
    for edge in &tile.edges {
        let info = world.bundle_info(&tile.selection, &edge.id).unwrap();
        let increasing = info.source.x < info.target.x;
        let expected_count = if increasing { 321 } else { 192 };
        assert_eq!(info.relation_count, expected_count);
        let mut cursor = None;
        let mut selected = BTreeSet::new();
        loop {
            let page = world
                .bundle_detail(&tile.selection, &edge.id, cursor.as_ref())
                .unwrap();
            assert_eq!(page.total_relations, expected_count);
            assert!(page.nodes.len() <= DETAIL_NODE_LIMIT);
            assert!(page.relations.len() <= DETAIL_EDGE_LIMIT);
            for row in page.relations {
                assert!(selected.insert(row.id.clone()));
                let source = &page.nodes[row.source as usize];
                let target = &page.nodes[row.target as usize];
                assert_eq!(source.x < target.x, increasing);
            }
            cursor = page.next;
            if increasing {
                bundle_cursor = bundle_cursor.or_else(|| cursor.clone());
            }
            if cursor.is_none() {
                break;
            }
        }
        assert_eq!(selected.len() as u64, expected_count);
    }
    let cursor = bundle_cursor.unwrap();
    let reverse = tile
        .edges
        .iter()
        .find(|edge| tile.glyphs[edge.source as usize].x > tile.glyphs[edge.target as usize].x)
        .unwrap();
    assert_eq!(
        world.bundle_detail(&tile.selection, &reverse.id, Some(&cursor)),
        Err(Error::InvalidDetailCursor)
    );
    assert_eq!(
        world.bundle_info(&tile.selection, "invented-missing-bundle"),
        Err(Error::DetailNotFound)
    );
    let other = world
        .tile(Cell::new(2, 2, 1).unwrap(), Budget::default())
        .unwrap();
    assert_eq!(
        world.tile_relations(&other.selection, first_cursor.as_ref(), 256),
        Err(Error::InvalidDetailCursor)
    );
    let other_forward = other
        .edges
        .iter()
        .find(|edge| other.glyphs[edge.source as usize].x < other.glyphs[edge.target as usize].x)
        .unwrap();
    assert_eq!(
        world.bundle_detail(&other.selection, &other_forward.id, Some(&cursor)),
        Err(Error::InvalidDetailCursor)
    );
    let compact = world
        .tile_with_profile(tile.cell, Budget::default(), TileProfile::AggregateOnly)
        .unwrap();
    let compact_forward = compact
        .edges
        .iter()
        .find(|edge| {
            compact.glyphs[edge.source as usize].x < compact.glyphs[edge.target as usize].x
        })
        .unwrap();
    assert_eq!(
        world.bundle_detail(&compact.selection, &compact_forward.id, Some(&cursor)),
        Err(Error::InvalidDetailCursor)
    );
    let changed = World::new(
        "invented-clipped".into(),
        16,
        nodes,
        relations[..512].to_vec(),
    )
    .unwrap();
    assert_eq!(
        changed.tile_relations(&tile.selection, None, 256),
        Err(Error::StaleDetailRevision)
    );
    assert_eq!(
        changed.bundle_detail(&tile.selection, &tile.edges[0].id, None),
        Err(Error::StaleDetailRevision)
    );
    assert_eq!(
        world.tile_relations(&tile.selection, None, 257),
        Err(Error::InvalidBudget)
    );
}

#[test]
fn filtered_candidate_pages_advance_without_scanning_the_whole_world() {
    let nodes = vec![point(0, 1, 1, 0), point(1, 900, 900, 0)];
    let mut relations: Vec<_> = (0..RELATION_CANDIDATE_LIMIT * 2 + 1)
        .map(|i| relation(format!("internal-{i:05}"), &nodes[0], &nodes[0]))
        .collect();
    relations.push(relation("visible".into(), &nodes[0], &nodes[1]));
    let world = World::new("invented-work-cap".into(), 16, nodes, relations).unwrap();
    let tile = world
        .tile(Cell::new(0, 0, 0).unwrap(), Budget::default())
        .unwrap();
    let mut cursor = None;
    let mut empty_continuations = 0;
    let mut seen = Vec::new();
    let mut total_candidates = 0;
    loop {
        let page = world
            .tile_relations(&tile.selection, cursor.as_ref(), 256)
            .unwrap();
        assert!(page.candidates <= RELATION_CANDIDATE_LIMIT);
        assert_eq!(page.total_rendered_relations, 1);
        total_candidates += page.candidates;
        if let Some(next) = &page.next {
            assert!(next.offset > cursor.as_ref().map_or(0, |previous| previous.offset));
            if page.relations.is_empty() {
                empty_continuations += 1;
            }
        }
        seen.extend(page.relations.into_iter().map(|r| r.relation_id));
        cursor = page.next;
        if cursor.is_none() {
            break;
        }
    }
    assert!(empty_continuations >= 2);
    assert_eq!(seen, ["visible"]);
    assert_eq!(total_candidates, RELATION_CANDIDATE_LIMIT * 2 + 2);

    let mut cursor = None;
    let mut empty_continuations = 0;
    let mut seen = Vec::new();
    loop {
        let page = world
            .bundle_detail(&tile.selection, &tile.edges[0].id, cursor.as_ref())
            .unwrap();
        assert!(page.candidates <= RELATION_CANDIDATE_LIMIT);
        assert_eq!(page.total_relations, 1);
        if let Some(next) = &page.next {
            assert!(next.offset > cursor.as_ref().map_or(0, |previous| previous.offset));
            if page.relations.is_empty() {
                empty_continuations += 1;
            }
        }
        seen.extend(page.relations.into_iter().map(|row| row.id));
        cursor = page.next;
        if cursor.is_none() {
            break;
        }
    }
    assert!(empty_continuations >= 2);
    assert_eq!(seen, ["visible"]);
}

#[test]
fn bundle_pages_preserve_every_relation_when_distinct_endpoints_fill_the_page() {
    let nodes: Vec<_> = (0..520)
        .map(|i| {
            point(
                i,
                if i < 260 { i + 1 } else { 16_000_000 + i },
                5_000_000,
                8,
            )
        })
        .collect();
    let relations: Vec<_> = (0..260)
        .map(|i| relation(format!("disjoint-{i:04}"), &nodes[i], &nodes[i + 260]))
        .collect();
    let expected: BTreeSet<_> = relations.iter().map(|row| row.id.clone()).collect();
    let world = World::new("invented-bundle-pages".into(), 16, nodes, relations).unwrap();
    let tile = world
        .tile(Cell::new(2, 1, 1).unwrap(), Budget::default())
        .unwrap();
    assert_eq!(tile.edges.len(), 1);
    assert_eq!(tile.edges[0].count, 260);
    let mut cursor = None;
    let mut seen = BTreeSet::new();
    let mut pages = 0;
    loop {
        let page = world
            .bundle_detail(&tile.selection, &tile.edges[0].id, cursor.as_ref())
            .unwrap();
        pages += 1;
        assert!(pages <= 6, "bounded endpoint pages must terminate");
        assert!(page.nodes.len() <= DETAIL_NODE_LIMIT);
        assert!(page.relations.len() <= DETAIL_EDGE_LIMIT);
        assert!(page.candidates <= RELATION_CANDIDATE_LIMIT);
        assert_eq!(page.total_relations, 260);
        if pages == 1 {
            assert_eq!(page.nodes.len(), 128);
            assert_eq!(page.relations.len(), 64);
        }
        for row in page.relations {
            assert!(seen.insert(row.id));
            assert!(page.nodes[row.source as usize].x < page.nodes[row.target as usize].x);
        }
        cursor = page.next;
        if cursor.is_none() {
            break;
        }
    }
    assert_eq!(seen, expected);
}
