//! Native ownership of imported rows, immutable worlds, and bounded publication pages.
//! Rates and health never enter this model. Interface bindings survive cold reloads.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

use dgraph_topology::{CanonicalEdge, CanonicalGraph};
use rustler::NifMap;
use serviceradar_topology_atlas::{
    ALGORITHM, Cell, Device, Position, Relation, WORLD_EXTENT, World, reconcile,
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
    pub active: bool,
}

impl RelationRow {
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
            active: true,
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
        build_world(
            self.layout_version,
            self.zmax,
            self.positions.values(),
            self.relations
                .into_values()
                .filter(|r| r.active)
                .collect::<Vec<_>>()
                .into(),
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
        let relations: Arc<[RelationRow]> =
            graph.relations.into_values().collect::<Vec<_>>().into();
        let digest = source_digest(&devices, &relations);
        let geometry: Vec<_> = relations.iter().map(RelationRow::geometry).collect();
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
    let info = Info {
        layout_version: layout_version.clone(),
        zmax,
        algorithm_version: ALGORITHM.into(),
        extent: WORLD_EXTENT,
        node_count: active.len() as u64,
        relation_count: relations.len() as u64,
    };
    let geometry = World::new(
        layout_version,
        zmax,
        active,
        relations.iter().map(RelationRow::geometry).collect(),
    )
    .map_err(|_| "invalid persisted world")?;
    let interface_degrees = interface_degrees(&relations);
    Ok(Arc::new(WorldState {
        geometry,
        info,
        relations,
        interface_degrees,
    }))
}

fn interface_degrees(relations: &[RelationRow]) -> Vec<[u32; 2]> {
    let mut counts = HashMap::<(&str, i32), u32>::new();
    for row in relations {
        let source = row
            .source_if_index
            .map(|index| (row.source_id.as_str(), index));
        let target = row
            .target_if_index
            .map(|index| (row.target_id.as_str(), index));
        if let Some(binding) = source {
            *counts.entry(binding).or_default() += 1;
        }
        // One canonical relation cannot make its own identical endpoint binding
        // ambiguous. All evidence classes count; no traffic policy lives here.
        if let Some(binding) = target.filter(|binding| source != Some(*binding)) {
            *counts.entry(binding).or_default() += 1;
        }
    }
    relations
        .iter()
        .map(|row| {
            let ids = [row.source_id.as_str(), row.target_id.as_str()];
            let interfaces = [row.source_if_index, row.target_if_index];
            std::array::from_fn(|side| {
                interfaces[side]
                    .and_then(|index| counts.get(&(ids[side], index)).copied())
                    .unwrap_or(0)
            })
        })
        .collect()
}

/// Typed graph conversion is a production boundary shared by the reader and reconciler.
pub struct SourceGraph {
    pub devices: BTreeMap<String, Device>,
    pub relations: BTreeMap<String, RelationRow>,
}

impl SourceGraph {
    pub fn from_canonical(graph: CanonicalGraph) -> Result<Self> {
        let (nodes, edges) = graph.into_parts();
        let mut devices = BTreeMap::new();
        for node in nodes {
            let label = node
                .hostname()
                .filter(|s| !s.trim().is_empty())
                .or_else(|| node.ip().filter(|s| !s.trim().is_empty()))
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
        let mut relations = BTreeMap::new();
        for edge in edges {
            let row = RelationRow::canonical(edge);
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
        }
        Ok(Self { devices, relations })
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
