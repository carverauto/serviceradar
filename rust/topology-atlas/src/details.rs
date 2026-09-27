//! Bounded detail selection over one immutable native world. These revisions
//! fence graph membership; the serving layer also pins publication generation
//! and fingerprints its current, authorized inventory enrichment.

use std::collections::HashMap;
use std::mem::size_of;
use std::ops::Range;

use sha2::{Digest, Sha256};

use crate::spatial::Line;
use crate::tiles::{digest_hex, digest_string};
use crate::{Cell, Error, Glyph, GlyphKind, Position, Relation, TileEdge, World};

pub const DETAIL_NODE_LIMIT: usize = 128;
pub const DETAIL_EDGE_LIMIT: usize = 256;
pub const DETAIL_MEMBER_LIMIT: usize = 64;
pub const RELATION_CANDIDATE_LIMIT: usize = 4096;
/// Includes owned vector and string capacities. A descriptor never owns a World.
pub const MAX_SELECTION_BYTES: usize = 1_048_576;

#[derive(Clone, Debug)]
pub struct TileSelection {
    pub(crate) world_revision: String,
    pub(crate) tile_revision: String,
    pub(crate) cell: Cell,
    pub(crate) glyphs: Vec<Glyph>,
    pub(crate) edges: Vec<TileEdge>,
    pub(crate) promoted: Vec<(u32, u32)>,
    pub(crate) groups: Vec<(Range<usize>, u32)>,
}

impl TileSelection {
    pub fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            + self.world_revision.capacity()
            + self.tile_revision.capacity()
            + self.glyphs.capacity() * size_of::<Glyph>()
            + self.edges.capacity() * size_of::<TileEdge>()
            + self.promoted.capacity() * size_of::<(u32, u32)>()
            + self.groups.capacity() * size_of::<(Range<usize>, u32)>()
            + self
                .glyphs
                .iter()
                .map(|g| g.id.capacity() + g.label.capacity())
                .sum::<usize>()
            + self.edges.iter().map(|e| e.id.capacity()).sum::<usize>()
    }

    fn endpoint(&self, index: u32, point: (f64, f64)) -> Option<u32> {
        if let Ok(i) = self
            .promoted
            .binary_search_by_key(&index, |&(node, _)| node)
        {
            return Some(self.promoted[i].1);
        }
        let group = self
            .groups
            .partition_point(|(range, _)| range.end <= index as usize);
        if let Some((range, glyph)) = self.groups.get(group) {
            if range.contains(&(index as usize)) {
                return Some(*glyph);
            }
        }
        self.glyphs
            .iter()
            .position(|g| {
                g.kind == GlyphKind::Boundary
                    && (g.x.to_bits(), g.y.to_bits()) == (point.0.to_bits(), point.1.to_bits())
            })
            .map(|i| i as u32)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AggregateSelection {
    world_revision: String,
    scope_revision: String,
    range: Range<usize>,
    excluded: Vec<usize>,
}

impl AggregateSelection {
    pub fn member_count(&self) -> usize {
        self.range.len() - self.excluded.len()
    }

    pub fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            + self.world_revision.capacity()
            + self.scope_revision.capacity()
            + self.excluded.capacity() * size_of::<usize>()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DetailScope {
    Neighborhood(String),
    /// Stable placement group, not a recomputed transport component.
    ComponentMembers(String),
    AggregateMembers(AggregateSelection),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DetailCursor {
    pub world_revision: String,
    pub scope_revision: String,
    pub node_page: u32,
    pub edge_page: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DetailRelation {
    pub id: String,
    pub source: u32,
    pub target: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DetailPage {
    pub world_revision: String,
    pub scope_revision: String,
    pub nodes: Vec<Position>,
    pub relations: Vec<DetailRelation>,
    /// Members of this scope, excluding the neighborhood's separately returned anchor.
    pub total_members: u64,
    /// Exact induced relation count for this selected node page, before edge paging.
    pub selected_relations: u64,
    /// Exact incident count for a neighborhood anchor; absent for member scopes.
    pub incident_relations: Option<u64>,
    pub next: Option<DetailCursor>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RelationCursor {
    pub world_revision: String,
    pub tile_revision: String,
    /// Raw spatial-index position; advancing this never rescans previous candidates.
    pub offset: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SelectedRelation {
    /// Index in this world's canonical relation-ID order; valid only for this revision.
    pub relation_index: u32,
    pub relation_id: String,
    pub rendered_edge_id: String,
    pub source_glyph: u32,
    pub target_glyph: u32,
    /// Whether canonical source/target order is reversed relative to the rendered edge.
    pub reversed: bool,
    pub bundle_members: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RelationPage {
    pub relations: Vec<SelectedRelation>,
    /// Total underlying membership of rendered edges, excluding internal-only links.
    pub total_rendered_relations: u64,
    pub candidates: usize,
    pub next: Option<RelationCursor>,
}

#[derive(Clone, Copy)]
struct Pair {
    peer: u32,
    start: u32,
    len: u32,
}

pub(crate) struct DetailIndex {
    offsets: Vec<u32>,
    peers: Vec<Pair>,
    relations: Vec<u32>,
    incident: Vec<u32>,
    components: HashMap<String, Vec<u32>>,
}

impl DetailIndex {
    pub(crate) fn new(positions: &[Position], endpoints: &[Line]) -> Result<Self, Error> {
        let capacity = endpoints
            .len()
            .checked_mul(2)
            .ok_or(Error::ExhaustedWorld)?;
        if capacity > u32::MAX as usize {
            return Err(Error::ExhaustedWorld);
        }
        let mut entries = Vec::with_capacity(capacity);
        let mut incident = vec![0; positions.len()];
        for (i, line) in endpoints.iter().enumerate() {
            entries.push((line.source, line.target, i as u32));
            incident[line.source as usize] += 1;
            if line.source != line.target {
                entries.push((line.target, line.source, i as u32));
                incident[line.target as usize] += 1;
            }
        }
        entries.sort_unstable();
        let mut offsets = vec![0; positions.len() + 1];
        let mut peers = Vec::<Pair>::new();
        let mut relations = Vec::with_capacity(entries.len());
        let mut previous = None;
        for (node, peer, relation) in entries {
            if previous != Some((node, peer)) {
                offsets[node as usize + 1] += 1;
                peers.push(Pair {
                    peer,
                    start: relations.len() as u32,
                    len: 0,
                });
                previous = Some((node, peer));
            }
            peers.last_mut().expect("entry created its pair").len += 1;
            relations.push(relation);
        }
        for i in 1..offsets.len() {
            offsets[i] += offsets[i - 1];
        }
        let mut components = HashMap::<String, Vec<u32>>::new();
        for (i, position) in positions.iter().enumerate() {
            components
                .entry(position.component_id.clone())
                .or_default()
                .push(i as u32);
        }
        Ok(Self {
            offsets,
            peers,
            relations,
            incident,
            components,
        })
    }

    fn peers(&self, node: u32) -> &[Pair] {
        &self.peers[self.offsets[node as usize] as usize..self.offsets[node as usize + 1] as usize]
    }

    fn pair(&self, a: u32, b: u32) -> Option<Range<usize>> {
        let peers = self.peers(a);
        let i = peers.binary_search_by_key(&b, |pair| pair.peer).ok()?;
        let pair = peers[i];
        Some(pair.start as usize..(pair.start + pair.len) as usize)
    }

    fn selected_pairs(&self, nodes: &[u32]) -> Vec<Range<usize>> {
        let mut sorted = nodes.to_vec();
        sorted.sort_unstable();
        let mut ranges = Vec::new();
        for (i, &a) in sorted.iter().enumerate() {
            for &b in &sorted[i..] {
                if let Some(range) = self.pair(a, b) {
                    ranges.push(range);
                }
            }
        }
        ranges
    }
}

impl World {
    pub fn detail_revision(&self) -> &str {
        &self.detail_revision
    }

    pub fn aggregate_selection(
        &self,
        selection: &TileSelection,
        glyph_id: &str,
    ) -> Result<AggregateSelection, Error> {
        self.check_detail_revision(&selection.world_revision)?;
        let glyph = selection
            .glyphs
            .iter()
            .position(|g| g.id == glyph_id && g.kind == GlyphKind::Aggregate)
            .ok_or(Error::DetailNotFound)?;
        let range = selection
            .groups
            .iter()
            .find(|(_, i)| *i as usize == glyph)
            .map(|(range, _)| range.clone())
            .ok_or(Error::DetailNotFound)?;
        let excluded = selection
            .promoted
            .iter()
            .map(|&(i, _)| i as usize)
            .filter(|i| range.contains(i))
            .collect();
        let mut hash = Sha256::new();
        digest_string(&mut hash, &selection.tile_revision);
        digest_string(&mut hash, glyph_id);
        Ok(AggregateSelection {
            world_revision: selection.world_revision.clone(),
            scope_revision: digest_hex(hash),
            range,
            excluded,
        })
    }

    pub fn detail(
        &self,
        scope: &DetailScope,
        cursor: Option<&DetailCursor>,
    ) -> Result<DetailPage, Error> {
        let scope_revision = self.scope_revision(scope)?;
        let (node_page, edge_page) = if let Some(cursor) = cursor {
            self.check_detail_revision(&cursor.world_revision)?;
            if cursor.scope_revision != scope_revision {
                return Err(Error::InvalidDetailCursor);
            }
            (cursor.node_page, cursor.edge_page)
        } else {
            (0, 0)
        };
        let (nodes, total, page_size, incident) = self.detail_nodes(scope, node_page)?;
        let groups = self.details.selected_pairs(&nodes);
        let relation_count = groups.iter().map(Range::len).sum::<usize>();
        let edge_offset = page_offset(edge_page, DETAIL_EDGE_LIMIT, relation_count)?;
        let selected = self.detail_relations(&nodes, &groups, edge_offset);
        let next_pages = if edge_offset + selected.len() < relation_count {
            Some((node_page, edge_page + 1))
        } else if (node_page as usize + 1) * page_size < total {
            Some((node_page + 1, 0))
        } else {
            None
        };
        Ok(DetailPage {
            world_revision: self.detail_revision.clone(),
            scope_revision: scope_revision.clone(),
            nodes: nodes
                .into_iter()
                .map(|i| self.positions[i as usize].clone())
                .collect(),
            relations: selected,
            total_members: total as u64,
            selected_relations: relation_count as u64,
            incident_relations: incident,
            next: next_pages.map(|(node_page, edge_page)| DetailCursor {
                world_revision: self.detail_revision.clone(),
                scope_revision,
                node_page,
                edge_page,
            }),
        })
    }

    fn scope_revision(&self, scope: &DetailScope) -> Result<String, Error> {
        let mut hash = Sha256::new();
        match scope {
            DetailScope::Neighborhood(id) => {
                hash.update([0]);
                digest_string(&mut hash, id);
            }
            DetailScope::ComponentMembers(id) => {
                hash.update([1]);
                digest_string(&mut hash, id);
            }
            DetailScope::AggregateMembers(selection) => {
                self.check_detail_revision(&selection.world_revision)?;
                hash.update([2]);
                digest_string(&mut hash, &selection.scope_revision);
            }
        }
        Ok(digest_hex(hash))
    }

    fn detail_nodes(
        &self,
        scope: &DetailScope,
        page: u32,
    ) -> Result<(Vec<u32>, usize, usize, Option<u64>), Error> {
        match scope {
            DetailScope::Neighborhood(id) => {
                let anchor = *self.identities.get(id).ok_or(Error::DetailNotFound)?;
                let peers = self.details.peers(anchor);
                let excluded: Vec<_> = peers
                    .binary_search_by_key(&anchor, |p| p.peer)
                    .ok()
                    .into_iter()
                    .collect();
                let total = peers.len() - excluded.len();
                let size = DETAIL_NODE_LIMIT - 1;
                let offset = page_offset(page, size, total)?;
                let mut nodes = vec![anchor];
                nodes.extend(
                    page_without(0..peers.len(), &excluded, offset, size)
                        .into_iter()
                        .map(|i| peers[i].peer),
                );
                Ok((
                    nodes,
                    total,
                    size,
                    Some(self.details.incident[anchor as usize] as u64),
                ))
            }
            DetailScope::ComponentMembers(id) => {
                let members = self
                    .details
                    .components
                    .get(id)
                    .ok_or(Error::DetailNotFound)?;
                let offset = page_offset(page, DETAIL_MEMBER_LIMIT, members.len())?;
                Ok((
                    members[offset..members.len().min(offset + DETAIL_MEMBER_LIMIT)].to_vec(),
                    members.len(),
                    DETAIL_MEMBER_LIMIT,
                    None,
                ))
            }
            DetailScope::AggregateMembers(selection) => {
                let total = selection.member_count();
                let offset = page_offset(page, DETAIL_MEMBER_LIMIT, total)?;
                let nodes = page_without(
                    selection.range.clone(),
                    &selection.excluded,
                    offset,
                    DETAIL_MEMBER_LIMIT,
                )
                .into_iter()
                .map(|i| i as u32)
                .collect();
                Ok((nodes, total, DETAIL_MEMBER_LIMIT, None))
            }
        }
    }

    fn detail_relations(
        &self,
        nodes: &[u32],
        groups: &[Range<usize>],
        mut offset: usize,
    ) -> Vec<DetailRelation> {
        let local: HashMap<_, _> = nodes
            .iter()
            .enumerate()
            .map(|(i, &node)| (node, i as u32))
            .collect();
        let mut rows = Vec::new();
        for group in groups {
            if offset >= group.len() {
                offset -= group.len();
                continue;
            }
            for &i in &self.details.relations[group.start + offset..group.end] {
                let relation = &self.relations[i as usize];
                let line = self.endpoints[i as usize];
                rows.push(DetailRelation {
                    id: relation.id.clone(),
                    source: local[&line.source],
                    target: local[&line.target],
                });
                if rows.len() == DETAIL_EDGE_LIMIT {
                    return rows;
                }
            }
            offset = 0;
        }
        rows
    }

    pub fn tile_relations(
        &self,
        selection: &TileSelection,
        cursor: Option<&RelationCursor>,
        limit: usize,
    ) -> Result<RelationPage, Error> {
        self.check_detail_revision(&selection.world_revision)?;
        if limit == 0 || limit > DETAIL_EDGE_LIMIT {
            return Err(Error::InvalidBudget);
        }
        let offset = if let Some(cursor) = cursor {
            self.check_detail_revision(&cursor.world_revision)?;
            if cursor.tile_revision != selection.tile_revision
                || cursor.offset > self.relations.len()
            {
                return Err(Error::InvalidDetailCursor);
            }
            cursor.offset
        } else {
            0
        };
        let mut rows = Vec::new();
        let (candidates, next) = self.segments.visit_page(
            selection.cell,
            offset,
            RELATION_CANDIDATE_LIMIT,
            |i, clip| {
                let line = self.endpoints[i as usize];
                let source = selection.endpoint(line.source, clip.source);
                let target = selection.endpoint(line.target, clip.target);
                if let (Some(source), Some(target)) = (source, target) {
                    if let Some(edge) = selection
                        .edges
                        .iter()
                        .find(|e| e.source == source && e.target == target)
                    {
                        rows.push(SelectedRelation {
                            relation_index: i,
                            relation_id: self.relations[i as usize].id.clone(),
                            rendered_edge_id: edge.id.clone(),
                            source_glyph: source,
                            target_glyph: target,
                            reversed: edge.source != source,
                            bundle_members: edge.count,
                        });
                    }
                }
                rows.len() < limit
            },
        );
        Ok(RelationPage {
            relations: rows,
            total_rendered_relations: selection.edges.iter().map(|e| e.count).sum(),
            candidates,
            next: next.map(|offset| RelationCursor {
                world_revision: self.detail_revision.clone(),
                tile_revision: selection.tile_revision.clone(),
                offset,
            }),
        })
    }

    fn check_detail_revision(&self, revision: &str) -> Result<(), Error> {
        if revision == self.detail_revision {
            Ok(())
        } else {
            Err(Error::StaleDetailRevision)
        }
    }
}

fn page_offset(page: u32, size: usize, total: usize) -> Result<usize, Error> {
    let offset = (page as usize)
        .checked_mul(size)
        .ok_or(Error::InvalidDetailCursor)?;
    if offset > 0 && offset >= total {
        Err(Error::DetailNotFound)
    } else {
        Ok(offset)
    }
}

/// Select by member rank without walking the skipped pages or excluded members.
fn page_without(
    range: Range<usize>,
    excluded: &[usize],
    offset: usize,
    limit: usize,
) -> Vec<usize> {
    let mut start = range.start + offset;
    for &removed in excluded {
        if removed <= start {
            start += 1;
        } else {
            break;
        }
    }
    let mut next_excluded = excluded.partition_point(|&i| i < start);
    let mut result = Vec::new();
    for i in start..range.end {
        if excluded.get(next_excluded) == Some(&i) {
            next_excluded += 1;
            continue;
        }
        if result.len() == limit {
            break;
        }
        result.push(i);
    }
    result
}

pub(crate) fn detail_revision(
    layout: &str,
    positions: &[Position],
    relations: &[Relation],
) -> String {
    let mut hash = Sha256::new();
    digest_string(&mut hash, layout);
    hash.update((positions.len() as u64).to_le_bytes());
    for position in positions {
        digest_string(&mut hash, &position.id);
        digest_string(&mut hash, &position.label);
        digest_string(&mut hash, &position.component_id);
        digest_string(&mut hash, position.parent_id.as_deref().unwrap_or(""));
        hash.update(position.x.to_le_bytes());
        hash.update(position.y.to_le_bytes());
        hash.update([
            position.min_zoom,
            position.component.z,
            position.placement_depth,
        ]);
        hash.update(position.component.x.to_le_bytes());
        hash.update(position.component.y.to_le_bytes());
    }
    hash.update((relations.len() as u64).to_le_bytes());
    for relation in relations {
        digest_string(&mut hash, &relation.id);
        digest_string(&mut hash, &relation.source);
        digest_string(&mut hash, &relation.target);
    }
    digest_hex(hash)
}
