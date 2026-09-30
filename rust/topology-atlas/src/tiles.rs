//! Immutable geometry shared by tile requests. Telemetry is deliberately absent:
//! changing health or traffic must not invalidate cached geometry.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::ops::Range;
use std::sync::Mutex;

use sha2::{Digest, Sha256};

use crate::details::{DetailIndex, MAX_SELECTION_BYTES, TileSelection, detail_revision};
use crate::layout::morton_index;
use crate::spatial::{Line, Point, SegmentIndex};
use crate::{Cell, Error, Position, Relation, WORLD_EXTENT};

#[derive(Clone, Copy, Debug)]
pub struct Budget {
    pub nodes: usize,
    pub edges: usize,
}

impl Default for Budget {
    fn default() -> Self {
        Self {
            nodes: 128,
            edges: 512,
        }
    }
}

// A 512-pixel tile resolves occupied 16-pixel cells. The same density rule
// applies to infrastructure and endpoints; node/edge budgets still cap detail.
const CLUSTER_DEPTH: u8 = 5;

/// `bins[side] == 0` keeps that side's canonical intersections. A positive count
/// is the equal-width cap both tiles that share the side apply.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Seam {
    bins: [u16; 4],
}

type RoutingKey = (u8, u32, u32, usize, usize);

#[derive(Clone, Copy)]
struct RoutingGrade {
    // None retains exact crossings. Dyadic caps only merge existing groups.
    cap: Option<u16>,
    crossings: [usize; 4],
}

/// AggregateOnly bounds identifiers independently of canonical identity length.
/// The encoder still owns the final serialized byte budget.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum TileProfile {
    #[default]
    Standard,
    AggregateOnly,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GlyphKind {
    Device,
    Aggregate,
    Boundary,
}

/// Graph semantics belong to immutable geometry, not a rotating telemetry page.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
#[repr(u8)]
pub enum TopologyClass {
    Backbone,
    Logical,
    Hosted,
    Endpoints,
    #[default]
    Unknown,
    Inferred,
}

impl TopologyClass {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Backbone => "backbone",
            Self::Logical => "logical",
            Self::Hosted => "hosted",
            Self::Endpoints => "endpoints",
            Self::Unknown => "unknown",
            Self::Inferred => "inferred",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Glyph {
    pub id: String,
    pub label: String,
    pub x: f64,
    pub y: f64,
    pub count: u64,
    pub kind: GlyphKind,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TileEdge {
    /// A canonical identity for one Standard relation, otherwise a bundle id.
    pub id: String,
    pub source: u32,
    pub target: u32,
    pub count: u64,
    pub topology_class: TopologyClass,
    /// Fractions of the canonical segment for continuous procedural flow.
    /// Bundles represent aggregate flow and use their own full segment.
    pub start: f64,
    pub end: f64,
}

#[derive(Clone, Debug)]
pub struct Tile {
    pub cell: Cell,
    pub profile: TileProfile,
    pub revision: String,
    pub glyphs: Vec<Glyph>,
    pub edges: Vec<TileEdge>,
    pub device_count: u64,
    pub internal_relations: u64,
    pub candidate_relations: usize,
    /// Bounded native descriptor retained separately from the encoded geometry.
    pub selection: TileSelection,
}

pub struct World {
    layout_version: String,
    z_max: u8,
    pub(crate) positions: Vec<Position>,
    codes: Vec<u64>,
    pub(crate) identities: HashMap<String, u32>,
    importance: BTreeMap<u8, Vec<u32>>,
    pub(crate) relations: Vec<Relation>,
    pub(crate) relation_classes: Vec<TopologyClass>,
    pub(crate) endpoints: Vec<Line>,
    pub(crate) segments: SegmentIndex,
    pub(crate) details: DetailIndex,
    pub(crate) detail_revision: String,
    routing: Mutex<BTreeMap<RoutingKey, RoutingGrade>>,
}

#[derive(Clone)]
struct Group {
    cell: Cell,
    range: Range<usize>,
    count: usize,
}

struct Plan {
    glyphs: Vec<Glyph>,
    promoted: HashMap<u32, u32>,
    groups: Vec<(Range<usize>, u32)>,
}

impl World {
    /// Captures graph classification once, in the canonical relation order.
    pub fn new_classified(
        layout_version: String,
        z_max: u8,
        positions: Vec<Position>,
        relations: Vec<Relation>,
        classify: impl Fn(&Relation) -> TopologyClass,
    ) -> Result<Self, Error> {
        let mut world = Self::new(layout_version, z_max, positions, relations)?;
        world.relation_classes = world.relations.iter().map(classify).collect();
        let mut hash = Sha256::new();
        digest_string(&mut hash, &world.detail_revision);
        for class in &world.relation_classes {
            hash.update([*class as u8]);
        }
        world.detail_revision = digest_hex(hash);
        Ok(world)
    }

    pub fn new(
        layout_version: String,
        z_max: u8,
        mut positions: Vec<Position>,
        mut relations: Vec<Relation>,
    ) -> Result<Self, Error> {
        if layout_version.is_empty() || layout_version.len() > 128 || z_max > 24 {
            return Err(Error::InvalidIdentity);
        }
        positions.sort_unstable_by_key(|p| morton_index(p.x, p.y));
        let mut codes = Vec::with_capacity(positions.len());
        let mut identities = HashMap::with_capacity(positions.len());
        let mut importance = BTreeMap::<u8, Vec<u32>>::new();
        let mut points = Vec::with_capacity(positions.len());
        if positions.len() > u32::MAX as usize || relations.len() > u32::MAX as usize {
            return Err(Error::ExhaustedWorld);
        }
        for (i, p) in positions.iter().enumerate() {
            if p.id.is_empty()
                || p.label.len() > 256
                || p.x >= WORLD_EXTENT
                || p.y >= WORLD_EXTENT
                || p.min_zoom > 24
            {
                return Err(Error::InvalidPosition(p.id.clone()));
            }
            if identities.insert(p.id.clone(), i as u32).is_some() {
                return Err(Error::DuplicateIdentity(p.id.clone()));
            }
            let code = morton_index(p.x, p.y);
            if codes.last() == Some(&code) {
                return Err(Error::InvalidPosition(p.id.clone()));
            }
            codes.push(code);
            points.push(Point { x: p.x, y: p.y });
            importance.entry(p.min_zoom).or_default().push(i as u32);
        }
        relations.sort_unstable_by(|a, b| a.id.cmp(&b.id));
        let mut endpoints = Vec::with_capacity(relations.len());
        for (i, edge) in relations.iter().enumerate() {
            if edge.id.is_empty() {
                return Err(Error::InvalidIdentity);
            }
            if i > 0 && relations[i - 1].id == edge.id {
                return Err(Error::DuplicateIdentity(edge.id.clone()));
            }
            let source = *identities
                .get(&edge.source)
                .ok_or_else(|| Error::MissingEndpoint(edge.source.clone()))?;
            let target = *identities
                .get(&edge.target)
                .ok_or_else(|| Error::MissingEndpoint(edge.target.clone()))?;
            endpoints.push(Line { source, target });
        }
        let details = DetailIndex::new(&positions, &endpoints)?;
        let detail_revision = detail_revision(&layout_version, &positions, &relations);
        let segments = SegmentIndex::new(points, endpoints.clone());
        Ok(Self {
            layout_version,
            z_max,
            positions,
            codes,
            identities,
            importance,
            relation_classes: vec![TopologyClass::Unknown; relations.len()],
            relations,
            endpoints,
            segments,
            details,
            detail_revision,
            routing: Mutex::new(BTreeMap::new()),
        })
    }

    pub fn search(&self, id: &str) -> Option<&Position> {
        self.identities
            .get(id)
            .map(|&i| &self.positions[i as usize])
    }

    /// Restrict tiled overview routes while retaining all canonical evidence
    /// in the bounded detail index. Selectors share this same segment index.
    pub fn with_overview_relations(mut self, include: impl Fn(&Relation) -> bool) -> Self {
        let mut hash = Sha256::new();
        digest_string(&mut hash, &self.detail_revision);
        let visible: Vec<_> = self.relations.iter().map(include).collect();
        for &included in &visible {
            hash.update([u8::from(included)]);
        }
        self.segments.retain(|i| visible[i as usize]);
        self.detail_revision = digest_hex(hash);
        self.routing.get_mut().unwrap().clear();
        self
    }

    pub fn device_count(&self) -> usize {
        self.positions.len()
    }

    pub fn tile(&self, cell: Cell, budget: Budget) -> Result<Tile, Error> {
        self.tile_with_profile(cell, budget, TileProfile::Standard)
    }

    pub fn tile_with_profile(
        &self,
        cell: Cell,
        budget: Budget,
        profile: TileProfile,
    ) -> Result<Tile, Error> {
        self.tile_with_routing_budget(cell, budget, profile, budget)
    }

    /// Encoding may reduce interior detail without changing a publication's
    /// shared boundary routing budget.
    pub fn tile_with_routing_budget(
        &self,
        cell: Cell,
        budget: Budget,
        profile: TileProfile,
        routing_budget: Budget,
    ) -> Result<Tile, Error> {
        Cell::new(cell.z, cell.x, cell.y)?;
        if cell.z > self.z_max {
            return Err(Error::InvalidCell);
        }
        // One interior plus four corner and four face glyphs have at most
        // 9 * 8 directed pairs per class. Five known classes plus unknown fit the production
        // 512-edge budget without moving corners or merging unlike classes.
        // Smaller caller budgets may reject dense mixed-class tiles.
        if budget.nodes < 9
            || budget.edges < 72
            || routing_budget.nodes < 9
            || routing_budget.edges < 72
        {
            return Err(Error::InvalidBudget);
        }
        let (seam, mut candidates) = self.shared_seam(cell, routing_budget);
        let mut limit = budget.nodes;
        loop {
            let plan = self.plan(cell, limit, profile);
            let (result, examined) = self.edges(cell, plan, budget, profile, seam);
            candidates += examined;
            if let Some(mut tile) = result {
                tile.candidate_relations = candidates;
                tile.revision = self.revision(&tile);
                tile.selection.tile_revision = tile.revision.clone();
                if tile.selection.retained_bytes() > MAX_SELECTION_BYTES {
                    return Err(Error::SelectionBudgetExceeded);
                }
            }
            if limit == 1 {
                break;
            }
            limit /= 2;
        }
        Err(Error::ExhaustedWorld)
    }

    fn range(&self, cell: Cell) -> Range<usize> {
        let (x, y) = cell.origin();
        let start = morton_index(x, y);
        let end = start + (1u64 << (2 * (24 - cell.z)));
        self.codes.partition_point(|&c| c < start)..self.codes.partition_point(|&c| c < end)
    }

    fn plan(&self, cell: Cell, limit: usize, profile: TileProfile) -> Plan {
        let range = self.range(cell);
        let mut selected = Vec::new();
        if profile == TileProfile::Standard {
            for (_, indexes) in self.importance.range(..=cell.z) {
                let start = indexes.partition_point(|&i| (i as usize) < range.start);
                for &i in &indexes[start..] {
                    if i as usize >= range.end || selected.len() == limit {
                        break;
                    }
                    let depth = cell.z.saturating_add(CLUSTER_DEPTH).min(24);
                    let position = &self.positions[i as usize];
                    let alone = Cell::at_point(depth, position.x, position.y)
                        .is_ok_and(|cluster| self.range(cluster).len() == 1);
                    if alone {
                        selected.push(i);
                    }
                }
                if selected.len() == limit {
                    break;
                }
            }
        }
        if selected.len() < range.len() {
            selected.truncate(limit / 2);
        }
        selected.sort_unstable();
        let remaining = |r: &Range<usize>| {
            r.len()
                - (selected.partition_point(|&i| (i as usize) < r.end)
                    - selected.partition_point(|&i| (i as usize) < r.start))
        };
        let mut groups = vec![Group {
            cell,
            count: remaining(&range),
            range,
        }];
        groups.retain(|g| g.count > 0);
        let mut unsplittable = Vec::new();
        while groups.len() + selected.len() < limit {
            let Some((i, _)) = groups
                .iter()
                .enumerate()
                .filter(|(_, g)| {
                    g.cell.z < 24
                        && g.cell.z < cell.z.saturating_add(CLUSTER_DEPTH)
                        && !unsplittable.contains(&g.cell)
                })
                .max_by_key(|(_, g)| (g.count, std::cmp::Reverse(g.cell)))
            else {
                break;
            };
            let parent = &groups[i];
            let mut children = Vec::new();
            for y in 0..2 {
                for x in 0..2 {
                    let child = Cell {
                        z: parent.cell.z + 1,
                        x: parent.cell.x * 2 + x,
                        y: parent.cell.y * 2 + y,
                    };
                    let range = self.range(child);
                    let count = remaining(&range);
                    if count > 0 {
                        children.push(Group {
                            cell: child,
                            range,
                            count,
                        });
                    }
                }
            }
            if groups.len() - 1 + children.len() + selected.len() > limit {
                unsplittable.push(parent.cell);
            } else {
                groups.remove(i);
                groups.extend(children);
            }
        }
        // A singleton has real coordinates and a name even below its semantic
        // promotion zoom. AggregateOnly still bounds canonical identifier bytes.
        if profile == TileProfile::Standard {
            groups.retain(|g| {
                if g.count != 1 {
                    return true;
                }
                let i = g
                    .range
                    .clone()
                    .find(|i| selected.binary_search(&(*i as u32)).is_err())
                    .expect("one remaining member") as u32;
                selected.push(i);
                selected.sort_unstable();
                false
            });
        }
        let mut glyphs = Vec::new();
        let mut promoted = HashMap::new();
        for i in selected {
            let p = &self.positions[i as usize];
            promoted.insert(i, glyphs.len() as u32);
            glyphs.push(Glyph {
                id: p.id.clone(),
                label: p.label.clone(),
                x: p.x.into(),
                y: p.y.into(),
                count: 1,
                kind: GlyphKind::Device,
            });
        }
        groups.sort_unstable_by_key(|g| g.range.start);
        let groups = groups
            .into_iter()
            .map(|g| {
                let index = glyphs.len() as u32;
                let (x, y) = g.cell.origin();
                let half = f64::from(g.cell.width()) / 2.0;
                glyphs.push(Glyph {
                    id: format!(
                        "aggregate:{}/{}/{}/{}",
                        self.layout_version, g.cell.z, g.cell.x, g.cell.y
                    ),
                    label: format!("{} devices", g.count),
                    x: f64::from(x) + half,
                    y: f64::from(y) + half,
                    count: g.count as u64,
                    kind: GlyphKind::Aggregate,
                });
                (g.range, index)
            })
            .collect();
        Plan {
            glyphs,
            promoted,
            groups,
        }
    }

    fn edges(
        &self,
        cell: Cell,
        mut plan: Plan,
        budget: Budget,
        profile: TileProfile,
        seam: Seam,
    ) -> (Option<Tile>, usize) {
        let mut proxies = BTreeMap::new();
        let mut bundles = BTreeMap::<(u32, u32, TopologyClass), TileEdge>::new();
        let mut internal = 0;
        let (candidates, complete) = self.segments.visit(cell, |i, clipped| {
            let edge = self.endpoints[i as usize];
            let class = self.relation_classes[i as usize];
            let source_point = published_portal(cell, clipped.source, seam);
            let target_point = published_portal(cell, clipped.target, seam);
            let quantized = source_point != clipped.source || target_point != clipped.target;
            let source = plan.endpoint(
                edge.source,
                source_point,
                &self.layout_version,
                cell.z,
                &mut proxies,
            );
            let target = plan.endpoint(
                edge.target,
                target_point,
                &self.layout_version,
                cell.z,
                &mut proxies,
            );
            let from = &plan.glyphs[source as usize];
            let to = &plan.glyphs[target as usize];
            if source == target {
                internal += 1;
            } else if from.x != to.x || from.y != to.y {
                bundles
                    .entry((source, target, class))
                    .and_modify(|edge| {
                        if edge.count == 1 {
                            edge.id = self.bundle_id(&from.id, &to.id, class);
                        }
                        edge.count += 1;
                        edge.start = 0.0;
                        edge.end = 1.0;
                    })
                    .or_insert_with(|| TileEdge {
                        id: if quantized || profile == TileProfile::AggregateOnly {
                            self.bundle_id(&from.id, &to.id, class)
                        } else {
                            self.relations[i as usize].id.clone()
                        },
                        source,
                        target,
                        count: 1,
                        topology_class: class,
                        start: if quantized { 0.0 } else { clipped.start },
                        end: if quantized { 1.0 } else { clipped.end },
                    });
            }
            plan.glyphs.len() <= budget.nodes && bundles.len() <= budget.edges
        });
        if !complete {
            return (None, candidates);
        }
        let device_count = plan.glyphs.iter().map(|g| g.count).sum();
        let edges: Vec<_> = bundles.into_values().collect();
        let mut promoted: Vec<_> = plan.promoted.into_iter().collect();
        promoted.sort_unstable();
        let selection = TileSelection {
            world_revision: self.detail_revision.clone(),
            tile_revision: String::new(),
            cell,
            profile,
            glyphs: plan.glyphs.clone(),
            edges: edges.clone(),
            promoted,
            groups: plan.groups,
            seam,
        };
        (
            Some(Tile {
                cell,
                profile,
                revision: String::new(),
                glyphs: plan.glyphs,
                edges,
                device_count,
                internal_relations: internal,
                candidate_relations: 0,
                selection,
            }),
            candidates,
        )
    }

    fn revision(&self, tile: &Tile) -> String {
        let mut hash = Sha256::new();
        digest_string(&mut hash, &self.layout_version);
        hash.update([tile.profile as u8]);
        hash.update([tile.cell.z]);
        hash.update(tile.cell.x.to_le_bytes());
        hash.update(tile.cell.y.to_le_bytes());
        hash.update(tile.internal_relations.to_le_bytes());
        hash.update((tile.glyphs.len() as u64).to_le_bytes());
        hash.update((tile.edges.len() as u64).to_le_bytes());
        for glyph in &tile.glyphs {
            digest_string(&mut hash, &glyph.id);
            digest_string(&mut hash, &glyph.label);
            hash.update(glyph.x.to_le_bytes());
            hash.update(glyph.y.to_le_bytes());
            hash.update(glyph.count.to_le_bytes());
            hash.update([glyph.kind as u8]);
        }
        for edge in &tile.edges {
            digest_string(&mut hash, &edge.id);
            hash.update(edge.source.to_le_bytes());
            hash.update(edge.target.to_le_bytes());
            hash.update(edge.count.to_le_bytes());
            hash.update([edge.topology_class as u8]);
            hash.update(edge.start.to_le_bytes());
            hash.update(edge.end.to_le_bytes());
        }
        digest_hex(hash)
    }

    fn bundle_id(&self, source: &str, target: &str, class: TopologyClass) -> String {
        let mut hash = Sha256::new();
        digest_string(&mut hash, &self.layout_version);
        digest_string(&mut hash, source);
        digest_string(&mut hash, target);
        hash.update([class as u8]);
        format!("bundle:{}", digest_hex(hash))
    }
}

impl Plan {
    fn endpoint(
        &mut self,
        index: u32,
        point: (f64, f64),
        layout_version: &str,
        zoom: u8,
        proxies: &mut BTreeMap<(u64, u64), u32>,
    ) -> u32 {
        if let Some(&glyph) = self.promoted.get(&index) {
            return glyph;
        }
        let group = self
            .groups
            .partition_point(|(range, _)| range.end <= index as usize);
        if let Some((range, glyph)) = self.groups.get(group)
            && range.contains(&(index as usize))
        {
            return *glyph;
        }
        let (x, y) = point;
        *proxies
            .entry((x.to_bits(), y.to_bits()))
            .or_insert_with(|| {
                let index = self.glyphs.len() as u32;
                self.glyphs.push(Glyph {
                    id: format!(
                        "boundary:{layout_version}/{zoom}/{:x}/{:x}",
                        x.to_bits(),
                        y.to_bits()
                    ),
                    label: String::new(),
                    x,
                    y,
                    count: 0,
                    kind: GlyphKind::Boundary,
                });
                index
            })
    }
}

fn side_of(cell: Cell, point: (f64, f64)) -> Option<usize> {
    let (left_i, top_i) = cell.origin();
    let width = f64::from(cell.width());
    let left = f64::from(left_i);
    let top = f64::from(top_i);
    let right = left + width;
    let bottom = top + width;
    let (x, y) = point;
    let vertical = if x == left {
        Some(0)
    } else if x == right {
        Some(1)
    } else {
        None
    };
    let horizontal = if y == top {
        Some(2)
    } else if y == bottom {
        Some(3)
    } else {
        None
    };
    match (vertical, horizontal) {
        (Some(_), Some(_)) | (None, None) => None,
        (Some(side), None) | (None, Some(side)) => Some(side),
    }
}

pub(crate) fn published_portal(cell: Cell, point: (f64, f64), seam: Seam) -> (f64, f64) {
    let Some(side) = side_of(cell, point) else {
        return point;
    };
    let bins = seam.bins[side];
    if bins == 0 {
        return point;
    }
    let (left_i, top_i) = cell.origin();
    let width = f64::from(cell.width());
    let (origin, coord, horizontal) = if side < 2 {
        (f64::from(top_i), point.1, false)
    } else {
        (f64::from(left_i), point.0, true)
    };
    let local = (coord - origin).clamp(0.0, width);
    let mut bin = ((local / width) * f64::from(bins)).floor() as u16;
    if bin >= bins {
        bin = bins - 1;
    }
    let center = origin + (f64::from(bin) + 0.5) * (width / f64::from(bins));
    if horizontal {
        (center, point.1)
    } else {
        (point.0, center)
    }
}

impl World {
    // A face uses the stricter of its two cells' grades. Grades are computed
    // before interior detail selection; neighbors and byte-budget retries must
    // not invent different portal positions for the same canonical crossing.
    fn shared_seam(&self, cell: Cell, budget: Budget) -> (Seam, usize) {
        let (own, mut examined) = self.routing_grade(cell, budget);
        let mut bins = [0; 4];
        let span = 1u32 << cell.z;
        let neighbors = [
            cell.x.checked_sub(1).map(|x| Cell { x, ..cell }),
            (cell.x + 1 < span).then_some(Cell {
                x: cell.x + 1,
                ..cell
            }),
            cell.y.checked_sub(1).map(|y| Cell { y, ..cell }),
            (cell.y + 1 < span).then_some(Cell {
                y: cell.y + 1,
                ..cell
            }),
        ];
        for (side, neighbor) in neighbors.into_iter().enumerate() {
            let (other, visits) =
                neighbor.map_or((own, 0), |cell| self.routing_grade(cell, budget));
            examined += visits;
            let cap = match (own.cap, other.cap) {
                (Some(a), Some(b)) => Some(a.min(b)),
                (a, b) => a.or(b),
            };
            let crossings = own.crossings[side].max(other.crossings[side ^ 1]);
            if let Some(cap) = cap.filter(|cap| crossings > usize::from(*cap)) {
                bins[side] = cap;
            }
        }
        (Seam { bins }, examined)
    }

    fn routing_grade(&self, cell: Cell, budget: Budget) -> (RoutingGrade, usize) {
        let key = (cell.z, cell.x, cell.y, budget.nodes, budget.edges);
        if let Some(grade) = self.routing.lock().unwrap().get(&key).copied() {
            return (grade, 0);
        }
        let mut seen: [BTreeSet<u64>; 4] = std::array::from_fn(|_| BTreeSet::new());
        let (mut examined, _) = self.segments.visit(cell, |_i, clipped| {
            for point in [clipped.source, clipped.target] {
                if let Some(side) = side_of(cell, point)
                    && seen[side].len() <= budget.nodes
                {
                    let free = if side < 2 { point.1 } else { point.0 };
                    seen[side].insert(free.to_bits());
                }
            }
            true
        });
        let crossings = std::array::from_fn(|side| seen[side].len());
        let fits = |seam| {
            self.edges(
                cell,
                self.plan(cell, 1, TileProfile::AggregateOnly),
                budget,
                TileProfile::AggregateOnly,
                seam,
            )
        };
        let (exact, visits) = fits(Seam::default());
        examined += visits;
        let cap = if exact.is_some() {
            None
        } else {
            // Powers of two produce nested partitions: adopting a neighbor's
            // smaller cap can only merge routes, never increase cardinality.
            let mut cap = 1u16;
            while usize::from(cap) * 2 <= budget.nodes.min(u16::MAX as usize) {
                cap *= 2;
            }
            loop {
                let bins = std::array::from_fn(|side| {
                    if crossings[side] > usize::from(cap) {
                        cap
                    } else {
                        0
                    }
                });
                let (tile, visits) = fits(Seam { bins });
                examined += visits;
                if tile.is_some() || cap == 1 {
                    break;
                }
                cap /= 2;
            }
            Some(cap)
        };
        let grade = RoutingGrade { cap, crossings };
        let mut cache = self.routing.lock().unwrap();
        if cache.len() >= 1024 {
            cache.pop_first();
        }
        cache.insert(key, grade);
        (grade, examined)
    }
}

pub(crate) fn digest_string(hash: &mut Sha256, value: &str) {
    hash.update((value.len() as u64).to_le_bytes());
    hash.update(value.as_bytes());
}

pub(crate) fn digest_hex(hash: Sha256) -> String {
    hash.finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
