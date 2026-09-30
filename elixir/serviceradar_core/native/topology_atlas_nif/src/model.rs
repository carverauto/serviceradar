//! Native ownership of imported rows, immutable worlds, and bounded publication pages.
//! Rates and health never enter this model. Interface bindings survive cold reloads.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::Arc;

use dgraph_topology::{CanonicalEdge, TopologyView};
use rustler::NifMap;
use serviceradar_topology_atlas::{
    reconcile, Cell, Device, Position, Relation, TopologyClass, World, ALGORITHM, WORLD_EXTENT,
};
use sha2::{Digest, Sha256};

pub const PAGE_LIMIT: usize = 500;
pub type Result<T> = std::result::Result<T, String>;

#[derive(Clone, Debug, PartialEq, Eq, NifMap)]
pub struct PositionRow {
    pub device_id: String,
    pub label: String,
    pub x: u32,
    pub y: u32,
    pub min_zoom: u8,
    pub parent_id: Option<String>,
    pub component_id: String,
    pub component_z: u8,
    pub component_x: u32,
    pub component_y: u32,
    pub placement_depth: u8,
    pub active: bool,
}

impl PositionRow {
    pub fn position(&self) -> Position {
        Position {
            id: self.device_id.clone(),
            label: self.label.clone(),
            x: self.x,
            y: self.y,
            min_zoom: self.min_zoom,
            parent_id: self.parent_id.clone(),
            component_id: self.component_id.clone(),
            component: Cell {
                z: self.component_z,
                x: self.component_x,
                y: self.component_y,
            },
            placement_depth: self.placement_depth,
        }
    }

    pub fn from_position(p: Position, active: bool) -> Self {
        Self {
            device_id: p.id,
            label: p.label,
            x: p.x,
            y: p.y,
            min_zoom: p.min_zoom,
            parent_id: p.parent_id,
            component_id: p.component_id,
            component_z: p.component.z,
            component_x: p.component.x,
            component_y: p.component.y,
            placement_depth: p.placement_depth,
            active,
        }
    }

    fn validate(&self) -> Result<()> {
        let cell = Cell::new(self.component_z, self.component_x, self.component_y)
            .map_err(|_| "invalid position component")?;
        if self.device_id.is_empty()
            || self.label.len() > 256
            || self.component_id.is_empty()
            || self.min_zoom > 24
            || self.component_z > 12
            || u16::from(self.component_z) + u16::from(self.placement_depth) > 24
            || !cell.contains(self.x, self.y)
        {
            return Err("invalid persisted position".into());
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, NifMap)]
pub struct RelationRow {
    pub relation_id: String,
    pub source_id: String,
    pub target_id: String,
    pub evidence_class: Option<String>,
    pub role: Option<String>,
    pub source_if_index: Option<i32>,
    pub source_if_name: Option<String>,
    pub target_if_index: Option<i32>,
    pub target_if_name: Option<String>,
    pub telemetry_eligible: bool,
    pub kind: String,
    pub active: bool,
    pub stale: bool,
    pub last_seen: Option<String>,
}

impl RelationRow {
    pub(crate) fn topology_class(&self) -> TopologyClass {
        match (self.kind.as_str(), self.evidence_class.as_deref()) {
            // Dgraph retains raw evidence names. An inferred segment may be
            // stored as ATTACHED_TO; that does not establish a physical link.
            (_, Some("inferred" | "inferred-segment")) => TopologyClass::Inferred,
            ("ATTACHED_TO", _) => TopologyClass::Endpoints,
            ("HOSTED_ON", _) => TopologyClass::Hosted,
            ("INFERRED_TO", _) => TopologyClass::Inferred,
            (_, Some("direct" | "direct-physical")) => TopologyClass::Backbone,
            (_, Some("logical" | "direct-logical")) => TopologyClass::Logical,
            (_, Some("endpoint-attachment")) => TopologyClass::Endpoints,
            (_, Some("hosted" | "hosted-virtual")) => TopologyClass::Hosted,
            _ => TopologyClass::Unknown,
        }
    }

    pub fn geometry(&self) -> Relation {
        Relation {
            id: self.relation_id.clone(),
            source: self.source_id.clone(),
            target: self.target_id.clone(),
        }
    }

    pub fn canonical(edge: CanonicalEdge) -> Self {
        // AB belongs to topo.src and BA belongs to topo.dst. Never sort endpoints
        // or reconstruct their interfaces from a link key.
        Self {
            relation_id: edge.link_key().to_owned(),
            source_id: edge.source().to_owned(),
            target_id: edge.target().to_owned(),
            evidence_class: nonempty(edge.evidence_class()),
            role: None,
            source_if_index: positive(edge.local_if_index_ab()),
            source_if_name: nonempty(edge.local_if_name_ab()),
            target_if_index: positive(edge.local_if_index_ba()),
            target_if_name: nonempty(edge.local_if_name_ba()),
            telemetry_eligible: edge.telemetry_eligible(),
            kind: "CANONICAL_TOPOLOGY".into(),
            active: true,
            stale: false,
            last_seen: None,
        }
    }

    fn validate(&self) -> Result<()> {
        if self.relation_id.is_empty()
            || self.source_id.is_empty()
            || self.target_id.is_empty()
            || self.source_if_index.is_some_and(|i| i <= 0)
            || self.target_if_index.is_some_and(|i| i <= 0)
        {
            return Err("invalid persisted relation".into());
        }
        Ok(())
    }
}

fn positive(value: i32) -> Option<i32> {
    (value > 0).then_some(value)
}
fn nonempty(value: &str) -> Option<String> {
    (!value.trim().is_empty()).then(|| value.to_owned())
}

#[derive(Clone, Debug, NifMap)]
pub struct InventoryRow {
    pub id: String,
    pub label: String,
    pub importance: u8,
}

#[derive(Clone, NifMap)]
pub struct Info {
    pub layout_version: String,
    pub zmax: u8,
    pub algorithm_version: String,
    pub extent: u32,
    pub bounds: Vec<Vec<u32>>,
    pub node_count: u64,
    pub relation_count: u64,
}

pub struct WorldState {
    pub geometry: World,
    pub info: Info,
    pub relations: Arc<[RelationRow]>,
    pub interface_degrees: Vec<[u32; 2]>,
}

pub struct Builder {
    layout_version: String,
    zmax: u8,
    positions: BTreeMap<String, PositionRow>,
    relations: BTreeMap<String, RelationRow>,
    inventory: HashMap<String, InventoryRow>,
}

impl Builder {
    pub fn new(layout_version: String, zmax: u8) -> Result<Self> {
        if layout_version.is_empty() || layout_version.len() > 128 || zmax > 24 {
            return Err("invalid layout metadata".into());
        }
        Ok(Self {
            layout_version,
            zmax,
            positions: BTreeMap::new(),
            relations: BTreeMap::new(),
            inventory: HashMap::new(),
        })
    }

    pub fn add_positions(&mut self, rows: Vec<PositionRow>) -> Result<()> {
        chunk(&rows)?;
        let mut ids = HashSet::new();
        for row in &rows {
            row.validate()?;
            if self.positions.contains_key(&row.device_id) || !ids.insert(&row.device_id) {
                return Err("duplicate persisted position".into());
            }
        }
        self.positions
            .extend(rows.into_iter().map(|r| (r.device_id.clone(), r)));
        Ok(())
    }

    pub fn add_relations(&mut self, rows: Vec<RelationRow>) -> Result<()> {
        chunk(&rows)?;
        let mut ids = HashSet::new();
        for row in &rows {
            row.validate()?;
            if self.relations.contains_key(&row.relation_id) || !ids.insert(&row.relation_id) {
                return Err("duplicate persisted relation".into());
            }
        }
        self.relations
            .extend(rows.into_iter().map(|r| (r.relation_id.clone(), r)));
        Ok(())
    }

    pub fn add_inventory(&mut self, rows: Vec<InventoryRow>) -> Result<()> {
        chunk(&rows)?;
        let mut ids = HashSet::new();
        for row in &rows {
            if row.id.is_empty() || row.label.len() > 256 || row.importance > 2 {
                return Err("invalid inventory projection".into());
            }
            if self.inventory.contains_key(&row.id) || !ids.insert(&row.id) {
                return Err("duplicate inventory identity".into());
            }
        }
        self.inventory
            .extend(rows.into_iter().map(|r| (r.id.clone(), r)));
        Ok(())
    }

    pub fn finish(self) -> Result<Arc<WorldState>> {
        let relations = normalize(self.relations.into_values().filter(|row| row.active));
        build_world(
            self.layout_version,
            self.zmax,
            self.positions.values(),
            relations.into(),
        )
    }

    pub fn reconcile(self, graph: SourceGraph) -> Result<Candidate> {
        let Self {
            layout_version,
            zmax,
            positions: old_positions,
            relations: old_relations,
            mut inventory,
        } = self;
        let mut devices = graph.devices;
        for device in devices.values_mut() {
            if let Some(row) = inventory.remove(&device.id) {
                device.label = row.label;
                device.importance = row.importance;
            }
        }
        drop(inventory);
        let raw_links = graph.raw_links;
        let relations: Arc<[RelationRow]> = normalize(graph.relations.into_values()).into();
        let pipeline_stats = publication_stats(raw_links, &relations);
        let digest = source_digest(&devices, &relations);
        let geometry = layout_forest(&relations);
        let prior: Vec<_> = old_positions.values().map(PositionRow::position).collect();
        let next = reconcile(devices.into_values().collect(), &geometry, &prior)
            .map_err(|_| "cannot reconcile persisted world")?;
        drop(prior);
        drop(geometry);
        let mut positions: BTreeMap<_, _> = old_positions
            .iter()
            .map(|(id, row)| {
                let mut retired = row.clone();
                retired.active = false;
                (id.clone(), retired)
            })
            .collect();
        for position in next {
            positions.insert(
                position.id.clone(),
                PositionRow::from_position(position, true),
            );
        }
        let positions: Vec<_> = positions.into_values().collect();
        let world = build_world(layout_version, zmax, positions.iter(), relations.clone())?;
        let deltas = Deltas::new(&old_positions, &old_relations, &positions, &relations);
        Ok(Candidate {
            world,
            source_digest: digest,
            positions,
            relations,
            deltas,
            pipeline_stats,
        })
    }
}

fn chunk<T>(rows: &[T]) -> Result<()> {
    if rows.len() > PAGE_LIMIT {
        Err("page exceeds 500 rows".into())
    } else {
        Ok(())
    }
}

fn build_world<'a>(
    layout_version: String,
    zmax: u8,
    positions: impl Iterator<Item = &'a PositionRow>,
    relations: Arc<[RelationRow]>,
) -> Result<Arc<WorldState>> {
    let active: Vec<_> = positions
        .filter(|p| p.active)
        .map(PositionRow::position)
        .collect();
    let bounds = active
        .iter()
        .fold(None::<(u32, u32, u32, u32)>, |bounds, p| {
            Some(match bounds {
                None => (p.x, p.y, p.x, p.y),
                Some((left, top, right, bottom)) => {
                    (left.min(p.x), top.min(p.y), right.max(p.x), bottom.max(p.y))
                }
            })
        })
        .map_or_else(
            || vec![vec![0, 0], vec![WORLD_EXTENT, WORLD_EXTENT]],
            |(left, top, right, bottom)| vec![vec![left, top], vec![right, bottom]],
        );
    let info = Info {
        layout_version: layout_version.clone(),
        zmax,
        algorithm_version: ALGORITHM.into(),
        extent: WORLD_EXTENT,
        bounds,
        node_count: active.len() as u64,
        relation_count: relations.len() as u64,
    };
    let geometry = World::new_classified(
        layout_version,
        zmax,
        active,
        relations.iter().map(RelationRow::geometry).collect(),
        |edge| {
            relations
                .binary_search_by(|row| row.relation_id.cmp(&edge.id))
                .map(|index| relations[index].topology_class())
                .unwrap_or_default()
        },
    )
    .map_err(|_| "invalid persisted world")?
    .with_relation_stale(|edge| {
        relations[relations
            .binary_search_by(|row| row.relation_id.cmp(&edge.id))
            .unwrap()]
        .stale
    });
    let overview: BTreeSet<_> = layout_forest(&relations)
        .iter()
        .map(|edge| {
            let row = &relations[relations
                .binary_search_by(|row| row.relation_id.cmp(&edge.id))
                .unwrap()];
            (
                device_pair(&row.source_id, &row.target_id),
                row.topology_class(),
            )
        })
        .collect();
    let geometry = geometry.with_overview_relations(|edge| {
        let row = &relations[relations
            .binary_search_by(|row| row.relation_id.cmp(&edge.id))
            .unwrap()];
        // Parallel physical bindings on the selected pair remain measurable;
        // a weaker class on that same pair remains separate detail evidence.
        overview.contains(&(
            device_pair(&row.source_id, &row.target_id),
            row.topology_class(),
        ))
    });
    let interface_degrees = interface_degrees(&relations);
    Ok(Arc::new(WorldState {
        geometry,
        info,
        relations,
        interface_degrees,
    }))
}

fn interface_degrees(relations: &[RelationRow]) -> Vec<[u32; 2]> {
    let mut bindings = HashMap::<(&str, i32), HashSet<&str>>::new();
    for row in relations.iter().filter(|row| physical_binding(row)) {
        if let Some(index) = row.source_if_index {
            bindings
                .entry((row.source_id.as_str(), index))
                .or_default()
                .insert(row.relation_id.as_str());
        }
        if let Some(index) = row.target_if_index {
            let binding = (row.target_id.as_str(), index);
            let source = row
                .source_if_index
                .map(|index| (row.source_id.as_str(), index));
            if source != Some(binding) {
                bindings
                    .entry(binding)
                    .or_default()
                    .insert(row.relation_id.as_str());
            }
        }
    }
    relations
        .iter()
        .map(|row| {
            let ids = [row.source_id.as_str(), row.target_id.as_str()];
            let interfaces = [row.source_if_index, row.target_if_index];
            std::array::from_fn(|side| {
                interfaces[side]
                    .and_then(|index| bindings.get(&(ids[side], index)).map(HashSet::len))
                    .unwrap_or(0) as u32
            })
        })
        .collect()
}

fn physical_binding(row: &RelationRow) -> bool {
    row.kind == "CANONICAL_TOPOLOGY"
        && physical_class(row)
        && row.role.as_ref().is_none_or(|role| role.is_empty())
}

/// Typed graph conversion is a production boundary shared by the reader and reconciler.
pub struct SourceGraph {
    pub devices: BTreeMap<String, Device>,
    pub relations: BTreeMap<String, RelationRow>,
    /// Admitted view edges before duplicate evidence is collapsed.
    pub raw_links: u64,
}

impl SourceGraph {
    pub fn from_view(view: TopologyView) -> Result<Self> {
        let (nodes, edges) = view.into_parts();
        let raw_links = edges.len() as u64;
        let mut devices = admit_devices(nodes)?;
        let mut relations = BTreeMap::new();
        for edge in edges {
            let stale = edge.stale();
            let seen = edge.last_seen().map(str::to_owned);
            let kind = edge.kind().to_owned();
            let mut row = RelationRow::canonical(edge.into_edge());
            row.kind = kind;
            row.stale = stale;
            row.last_seen = seen;
            if row.kind != "CANONICAL_TOPOLOGY" || stale {
                row.telemetry_eligible = false;
            }
            insert_relation(&mut devices, &mut relations, row)?;
        }
        Ok(Self {
            devices,
            relations,
            raw_links,
        })
    }
}

fn admit_devices(nodes: Vec<dgraph_topology::CanonicalDevice>) -> Result<BTreeMap<String, Device>> {
    let mut devices = BTreeMap::new();
    for node in nodes {
        let label = node
            .hostname()
            .filter(|value| !value.trim().is_empty())
            .or_else(|| node.ip().filter(|value| !value.trim().is_empty()))
            .unwrap_or(node.id());
        let device = Device {
            id: node.id().to_owned(),
            label: bounded_label(label),
            importance: 2,
        };
        if device.id.is_empty() {
            return Err("empty canonical device identity".into());
        }
        devices
            .entry(device.id.clone())
            .and_modify(|old: &mut Device| {
                if device.label < old.label {
                    old.label.clone_from(&device.label);
                }
            })
            .or_insert(device);
    }
    Ok(devices)
}

fn insert_relation(
    devices: &mut BTreeMap<String, Device>,
    relations: &mut BTreeMap<String, RelationRow>,
    row: RelationRow,
) -> Result<()> {
    row.validate()?;
    for id in [&row.source_id, &row.target_id] {
        devices.entry(id.clone()).or_insert_with(|| Device {
            id: id.clone(),
            label: bounded_label(id),
            importance: 2,
        });
    }
    if relations.insert(row.relation_id.clone(), row).is_some() {
        return Err("duplicate canonical relation".into());
    }
    Ok(())
}

fn physical_class(row: &RelationRow) -> bool {
    matches!(
        row.evidence_class.as_deref(),
        Some("direct-physical") | Some("direct")
    )
}

fn normalize(rows: impl IntoIterator<Item = RelationRow>) -> Vec<RelationRow> {
    let rows: Vec<RelationRow> = rows.into_iter().collect();
    if rows.len() < 2 {
        return rows;
    }
    let mut groups: HashMap<(&str, &str), Vec<usize>> = HashMap::new();
    for (index, row) in rows.iter().enumerate() {
        groups
            .entry(device_pair(&row.source_id, &row.target_id))
            .or_default()
            .push(index);
    }
    let mut kept = Vec::new();
    for members in groups.into_values() {
        let mut resolved: Vec<_> = members
            .iter()
            .map(|&index| {
                let original = &rows[index];
                let mut row = original.clone();
                for source in [true, false] {
                    if endpoint(original, source).0.is_some() {
                        continue;
                    }
                    let device = if source {
                        &original.source_id
                    } else {
                        &original.target_id
                    };
                    let indices: HashSet<_> = members
                        .iter()
                        .map(|&i| &rows[i])
                        .filter(|other| compatible_link(original, other))
                        .filter_map(|other| port(other, device).0)
                        .collect();
                    if indices.len() == 1 {
                        absorb(&mut row, source, (indices.into_iter().next(), None));
                    }
                }
                row
            })
            .collect();
        // Resolve complete bindings before aliases. An alias compatible with
        // two distinct port pairs is ambiguous; it must not join those cables.
        resolved.sort_by_key(|row| {
            (
                std::cmp::Reverse(
                    usize::from(row.source_if_index.is_some())
                        + usize::from(row.target_if_index.is_some()),
                ),
                row.relation_id.clone(),
            )
        });
        let mut links: Vec<RelationRow> = Vec::new();
        for row in &resolved {
            let matches: Vec<_> = links
                .iter()
                .enumerate()
                .filter(|(_, link)| compatible_link(link, row))
                .map(|(i, _)| i)
                .collect();
            if let [index] = matches.as_slice() {
                let keeper = &mut links[*index];
                if prefer(row, keeper) {
                    let old = std::mem::replace(keeper, row.clone());
                    merge_ports(keeper, &old);
                } else {
                    merge_ports(keeper, row);
                }
            } else {
                links.push(row.clone());
            }
        }
        kept.extend(links);
    }
    kept.sort_by(|left, right| left.relation_id.cmp(&right.relation_id));
    kept
}

// The overview projection selects a trusted spanning forest before ELK
// (topology_overview_projection.js, prepareTopologyOverviewInput). Apply that
// same ordering at publication scale. Cross-links stay in WorldState; only the
// parent forest is reduced, so tile zoom never authors new network bindings.
fn layout_forest(rows: &[RelationRow]) -> Vec<Relation> {
    let index: HashMap<_, _> = rows
        .iter()
        .flat_map(|row| [row.source_id.as_str(), row.target_id.as_str()])
        .collect::<BTreeSet<_>>()
        .into_iter()
        .enumerate()
        .map(|(i, id)| (id, i))
        .collect();
    let mut candidates: Vec<_> = rows.iter().collect();
    candidates.sort_unstable_by(|left, right| {
        (
            trust_rank(left),
            u8::from(left.stale),
            std::cmp::Reverse(left.last_seen.as_deref().unwrap_or("")),
            device_pair(&left.source_id, &left.target_id),
            &left.relation_id,
        )
            .cmp(&(
                trust_rank(right),
                u8::from(right.stale),
                std::cmp::Reverse(right.last_seen.as_deref().unwrap_or("")),
                device_pair(&right.source_id, &right.target_id),
                &right.relation_id,
            ))
    });
    let mut parent: Vec<_> = (0..index.len()).collect();
    let mut rank = vec![0; index.len()];
    let mut forest = Vec::with_capacity(index.len());
    for row in candidates {
        let left = index[row.source_id.as_str()];
        let right = index[row.target_id.as_str()];
        if find(&mut parent, left) != find(&mut parent, right) {
            union(&mut parent, &mut rank, left, right);
            forest.push(row.geometry());
        }
    }
    forest
}

fn trust_rank(row: &RelationRow) -> u8 {
    match row.topology_class() {
        TopologyClass::Backbone => 0,
        TopologyClass::Logical => 1,
        TopologyClass::Hosted => 2,
        TopologyClass::Endpoints => 3,
        TopologyClass::Inferred => 4,
        _ => 5,
    }
}

fn device_pair<'a>(source: &'a str, target: &'a str) -> (&'a str, &'a str) {
    if source <= target {
        (source, target)
    } else {
        (target, source)
    }
}

fn compatible_link(left: &RelationRow, right: &RelationRow) -> bool {
    if left.kind != right.kind
        || left.evidence_class != right.evidence_class
        || left.role != right.role
    {
        return false;
    }
    let aligned = left.source_id == right.source_id && left.target_id == right.target_id;
    let swapped = left.source_id == right.target_id && left.target_id == right.source_id;
    (aligned && same_ports(left, right, false)) || (swapped && same_ports(left, right, true))
}

fn same_ports(left: &RelationRow, right: &RelationRow, swapped: bool) -> bool {
    ports_compatible(endpoint(left, true), endpoint(right, !swapped))
        && ports_compatible(endpoint(left, false), endpoint(right, swapped))
}

fn endpoint(row: &RelationRow, source: bool) -> (Option<i32>, Option<&str>) {
    if source {
        (row.source_if_index, row.source_if_name.as_deref())
    } else {
        (row.target_if_index, row.target_if_name.as_deref())
    }
}

fn port<'a>(row: &'a RelationRow, device: &str) -> (Option<i32>, Option<&'a str>) {
    if device == row.source_id {
        (row.source_if_index, row.source_if_name.as_deref())
    } else {
        (row.target_if_index, row.target_if_name.as_deref())
    }
}

fn ports_compatible(left: (Option<i32>, Option<&str>), right: (Option<i32>, Option<&str>)) -> bool {
    // Indexes identify interfaces; names may differ between discovery sources.
    // Names resolve an alias only when at least one side lacks an index.
    if let (Some(left), Some(right)) = (left.0, right.0) {
        return left == right;
    }
    let index_conflict = matches!((left.0, right.0), (Some(a), Some(b)) if a != b);
    let name_conflict = matches!((left.1, right.1), (Some(a), Some(b)) if a != b);
    let shared = matches!((left.0, right.0), (Some(a), Some(b)) if a == b)
        || matches!((left.1, right.1), (Some(a), Some(b)) if a == b);
    !index_conflict && !name_conflict && shared
}

fn prefer(candidate: &RelationRow, keeper: &RelationRow) -> bool {
    match (candidate.stale, keeper.stale) {
        (false, true) => true,
        (true, false) => false,
        _ => match (candidate.telemetry_eligible, keeper.telemetry_eligible) {
            (true, false) => true,
            (false, true) => false,
            _ => match (physical_class(candidate), physical_class(keeper)) {
                (true, false) => true,
                (false, true) => false,
                _ => match (&candidate.last_seen, &keeper.last_seen) {
                    (Some(candidate_seen), Some(keeper_seen)) if candidate_seen != keeper_seen => {
                        candidate_seen > keeper_seen
                    }
                    (Some(_), None) => true,
                    (None, Some(_)) => false,
                    _ => candidate.relation_id < keeper.relation_id,
                },
            },
        },
    }
}

fn merge_ports(keeper: &mut RelationRow, other: &RelationRow) {
    let source = keeper.source_id.clone();
    let target = keeper.target_id.clone();
    absorb(keeper, true, port(other, &source));
    absorb(keeper, false, port(other, &target));
}

fn absorb(row: &mut RelationRow, source_side: bool, observed: (Option<i32>, Option<&str>)) {
    let (index, name) = if source_side {
        (&mut row.source_if_index, &mut row.source_if_name)
    } else {
        (&mut row.target_if_index, &mut row.target_if_name)
    };
    if index.is_none() {
        *index = observed.0;
    }
    if name.is_none() {
        *name = observed.1.map(str::to_owned);
    }
}

fn find(parent: &mut [usize], mut index: usize) -> usize {
    while parent[index] != index {
        parent[index] = parent[parent[index]];
        index = parent[index];
    }
    index
}

fn union(parent: &mut [usize], rank: &mut [u8], left: usize, right: usize) {
    let mut left = find(parent, left);
    let mut right = find(parent, right);
    if left == right {
        return;
    }
    if rank[left] < rank[right] {
        std::mem::swap(&mut left, &mut right);
    }
    parent[right] = left;
    if rank[left] == rank[right] {
        rank[left] = rank[left].saturating_add(1);
    }
}

fn bounded_label(value: &str) -> String {
    let mut end = value.len().min(256);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

// Length-prefixed fields avoid delimiter collisions; order is canonical and does
// not depend on Dgraph UIDs, request pages, refresh time, rates, or status.
fn source_digest(devices: &BTreeMap<String, Device>, relations: &[RelationRow]) -> String {
    let mut hash = Sha256::new();
    field(&mut hash, "topology-world-source-v1");
    hash.update((devices.len() as u64).to_be_bytes());
    for d in devices.values() {
        field(&mut hash, &d.id);
        field(&mut hash, &d.label);
        hash.update([d.importance]);
    }
    hash.update((relations.len() as u64).to_be_bytes());
    for r in relations {
        for value in [&r.relation_id, &r.source_id, &r.target_id] {
            field(&mut hash, value);
        }
        for value in [
            &r.evidence_class,
            &r.role,
            &r.source_if_name,
            &r.target_if_name,
        ] {
            hash.update([u8::from(value.is_some())]);
            if let Some(value) = value {
                field(&mut hash, value);
            }
        }
        for index in [r.source_if_index, r.target_if_index] {
            hash.update(index.unwrap_or(0).to_be_bytes());
        }
        hash.update([u8::from(r.telemetry_eligible)]);
        hash.update([u8::from(r.stale)]);
        hash.update([u8::from(r.last_seen.is_some())]);
        if let Some(seen) = &r.last_seen {
            field(&mut hash, seen);
        }
        field(&mut hash, &r.kind);
    }
    hash.finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn field(hash: &mut Sha256, value: &str) {
    hash.update((value.len() as u64).to_be_bytes());
    hash.update(value.as_bytes());
}

pub struct Candidate {
    pub world: Arc<WorldState>,
    pub source_digest: String,
    pub positions: Vec<PositionRow>,
    pub relations: Arc<[RelationRow]>,
    pub deltas: Deltas,
    pub pipeline_stats: PipelineStats,
}

/// Counts taken from the relations already admitted for this publication.
#[derive(Clone, Debug, NifMap)]
pub struct PipelineStats {
    pub raw_links: u64,
    pub unique_pairs: u64,
    pub final_edges: u64,
    pub final_direct: u64,
    pub final_inferred: u64,
    pub final_attachment: u64,
    pub edge_class_backbone: u64,
    pub edge_class_attachment: u64,
    pub edge_class_inferred: u64,
    pub edge_class_hosted: u64,
    pub edge_class_observed: u64,
    pub backbone_edge_count: u64,
}

fn publication_stats(raw_links: u64, relations: &[RelationRow]) -> PipelineStats {
    let mut pairs = BTreeSet::new();
    let mut direct = 0u64;
    let mut inferred = 0u64;
    let mut attachment = 0u64;
    let mut backbone = 0u64;
    let mut hosted = 0u64;
    for row in relations {
        pairs.insert(device_pair(&row.source_id, &row.target_id));
        match row.topology_class() {
            TopologyClass::Backbone => {
                direct += 1;
                backbone += 1;
            }
            TopologyClass::Logical | TopologyClass::Unknown => backbone += 1,
            TopologyClass::Hosted => hosted += 1,
            TopologyClass::Endpoints => attachment += 1,
            TopologyClass::Inferred => inferred += 1,
        }
    }
    PipelineStats {
        raw_links,
        unique_pairs: pairs.len() as u64,
        final_edges: relations.len() as u64,
        final_direct: direct,
        final_inferred: inferred,
        final_attachment: attachment,
        edge_class_backbone: backbone,
        edge_class_attachment: attachment,
        edge_class_inferred: inferred,
        edge_class_hosted: hosted,
        edge_class_observed: 0,
        backbone_edge_count: backbone,
    }
}

#[derive(Clone, NifMap)]
pub struct PositionUpdate {
    pub device_id: String,
    pub label: String,
    pub min_zoom: u8,
}

#[derive(Default)]
pub struct Deltas {
    pub insert_positions: Vec<usize>,
    pub update_positions: Vec<PositionUpdate>,
    pub activate_device_ids: Vec<String>,
    pub deactivate_device_ids: Vec<String>,
    pub upsert_relations: Vec<usize>,
    pub deactivate_relation_ids: Vec<String>,
}

impl Deltas {
    fn new(
        old_positions: &BTreeMap<String, PositionRow>,
        old_relations: &BTreeMap<String, RelationRow>,
        positions: &[PositionRow],
        relations: &[RelationRow],
    ) -> Self {
        let mut delta = Self::default();
        for (i, row) in positions.iter().enumerate() {
            match old_positions.get(&row.device_id) {
                None => delta.insert_positions.push(i),
                Some(old) => {
                    if row.label != old.label || row.min_zoom != old.min_zoom {
                        delta.update_positions.push(PositionUpdate {
                            device_id: row.device_id.clone(),
                            label: row.label.clone(),
                            min_zoom: row.min_zoom,
                        });
                    }
                    if row.active && !old.active {
                        delta.activate_device_ids.push(row.device_id.clone());
                    }
                    if !row.active && old.active {
                        delta.deactivate_device_ids.push(row.device_id.clone());
                    }
                }
            }
        }
        let mut retained = HashSet::with_capacity(relations.len());
        for (i, row) in relations.iter().enumerate() {
            retained.insert(row.relation_id.as_str());
            if old_relations.get(&row.relation_id) != Some(row) {
                delta.upsert_relations.push(i);
            }
        }
        delta.deactivate_relation_ids = old_relations
            .values()
            .filter(|r| r.active && !retained.contains(r.relation_id.as_str()))
            .map(|r| r.relation_id.clone())
            .collect();
        delta
    }
}

pub fn page_range(
    length: usize,
    cursor: usize,
    limit: usize,
) -> Result<(std::ops::Range<usize>, Option<usize>)> {
    if limit == 0 || limit > PAGE_LIMIT || cursor > length {
        return Err("invalid page".into());
    }
    let end = cursor.saturating_add(limit).min(length);
    Ok((cursor..end, (end < length).then_some(end)))
}
