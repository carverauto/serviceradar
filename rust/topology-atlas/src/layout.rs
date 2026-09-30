use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};

use sha2::{Digest, Sha256};

use crate::{Cell, Device, Error, Position, Relation};

/// Build a deterministic hierarchical placement, or add to a persisted one.
/// Supply inactive positions too: a returning identity reuses its old location,
/// and another device cannot occupy its reservation in the meantime.
pub fn reconcile(
    mut devices: Vec<Device>,
    relations: &[Relation],
    previous: &[Position],
) -> Result<Vec<Position>, Error> {
    devices.sort_unstable_by(|a, b| a.id.cmp(&b.id));
    let index = device_index(&devices)?;
    let adjacency = adjacency(&index, relations, devices.len())?;
    let known = previous_index(previous)?;
    let mut slots = ComponentSlots::from_previous(previous);
    let mut cells = ComponentCells::new(previous)?;
    let forest = forest(&devices, &adjacency, &known);
    let fresh_components = forest
        .iter()
        .filter(|tree| {
            !tree
                .iter()
                .any(|(i, _)| known.contains_key(devices[*i].id.as_str()))
        })
        .count();
    let component_depth = previous
        .iter()
        .map(|p| p.component.z)
        .min()
        .unwrap_or_else(|| depth_for(fresh_components.saturating_mul(4)).max(1));
    let mut positions: Vec<Option<Position>> = vec![None; devices.len()];

    let elk = (fresh_components > 0)
        .then(crate::elk::Elk::new)
        .transpose()?;
    for tree in forest {
        let anchor = tree
            .iter()
            .find_map(|(i, _)| known.get(devices[*i].id.as_str()).copied());
        let root = tree[0].0;
        let drawing = if anchor.is_none() {
            Some(crate::elk_hierarchy::compose(&tree, elk.as_ref().unwrap())?)
        } else {
            None
        };
        let component = if let Some(drawing) = &drawing {
            let finest = crate::elk_hierarchy::finest_cell(drawing, tree.len())?;
            cells.reserve(&devices[root].id, component_depth, finest)?
        } else {
            anchor.expect("anchored tree").component
        };
        let component_id =
            anchor.map_or_else(|| devices[root].id.clone(), |p| p.component_id.clone());
        let placement_depth = anchor.map_or_else(
            || depth_for(tree.len().saturating_mul(4)),
            |p| p.placement_depth,
        );
        if u16::from(component.z) + u16::from(placement_depth) > 24 {
            return Err(Error::ExhaustedWorld);
        }
        let fresh_geometry = drawing
            .as_ref()
            .map(|drawing| crate::elk_hierarchy::project(drawing, component, tree.len()))
            .transpose()?;
        for &(i, parent) in &tree {
            let device = &devices[i];
            let position = if let Some(old) = known.get(device.id.as_str()) {
                let mut old = (*old).clone();
                old.label.clone_from(&device.label);
                old.min_zoom = minimum_zoom(device.importance);
                old
            } else if anchor.is_none() {
                let (x, y) = fresh_geometry.as_ref().unwrap()[&i];
                Position {
                    id: device.id.clone(),
                    label: device.label.clone(),
                    x,
                    y,
                    min_zoom: minimum_zoom(device.importance),
                    parent_id: parent.map(|p| devices[p].id.clone()),
                    component_id: component_id.clone(),
                    component,
                    placement_depth,
                }
            } else {
                let parent_position = parent
                    .and_then(|p| positions[p].as_ref())
                    .or(anchor)
                    .expect("component anchor");
                let (x, y, depth) = slots
                    .get_mut(&parent_position.component)
                    .expect("persisted component")
                    .allocate(parent_position)?;
                Position {
                    id: device.id.clone(),
                    label: device.label.clone(),
                    x,
                    y,
                    min_zoom: minimum_zoom(device.importance),
                    parent_id: Some(parent_position.id.clone()),
                    component_id: parent_position.component_id.clone(),
                    component: parent_position.component,
                    placement_depth: depth,
                }
            };
            positions[i] = Some(position);
        }
    }
    Ok(positions
        .into_iter()
        .map(|p| p.expect("every device visited"))
        .collect())
}

fn device_index(devices: &[Device]) -> Result<HashMap<&str, usize>, Error> {
    let mut index = HashMap::with_capacity(devices.len());
    for (i, device) in devices.iter().enumerate() {
        if device.id.is_empty() || device.label.len() > 256 || device.importance > 2 {
            return Err(Error::InvalidIdentity);
        }
        if index.insert(device.id.as_str(), i).is_some() {
            return Err(Error::DuplicateIdentity(device.id.clone()));
        }
    }
    Ok(index)
}

fn adjacency(
    index: &HashMap<&str, usize>,
    relations: &[Relation],
    count: usize,
) -> Result<Vec<Vec<usize>>, Error> {
    let mut edges = vec![Vec::new(); count];
    for relation in relations {
        let source = *index
            .get(relation.source.as_str())
            .ok_or_else(|| Error::MissingEndpoint(relation.source.clone()))?;
        let target = *index
            .get(relation.target.as_str())
            .ok_or_else(|| Error::MissingEndpoint(relation.target.clone()))?;
        if source != target {
            edges[source].push(target);
            edges[target].push(source);
        }
    }
    for neighbours in &mut edges {
        neighbours.sort_unstable();
        neighbours.dedup();
    }
    Ok(edges)
}

fn previous_index(previous: &[Position]) -> Result<HashMap<&str, &Position>, Error> {
    let mut index = HashMap::with_capacity(previous.len());
    let mut points = HashSet::with_capacity(previous.len());
    let mut components = HashMap::new();
    let mut component_ids = HashMap::new();
    for position in previous {
        let valid_cell = Cell::new(
            position.component.z,
            position.component.x,
            position.component.y,
        )
        .is_ok();
        if !valid_cell
            || position.component.z > 12
            || !position.component.contains(position.x, position.y)
            || u16::from(position.component.z) + u16::from(position.placement_depth) > 24
            || !points.insert(point_key(position.x, position.y))
        {
            return Err(Error::InvalidPosition(position.id.clone()));
        }
        if let Some(old) = components.insert(position.component_id.as_str(), position.component)
            && old != position.component
        {
            return Err(Error::InvalidPosition(position.id.clone()));
        }
        if let Some(old) = component_ids.insert(position.component, position.component_id.as_str())
            && old != position.component_id
        {
            return Err(Error::InvalidPosition(position.id.clone()));
        }
        if index.insert(position.id.as_str(), position).is_some() {
            return Err(Error::DuplicateIdentity(position.id.clone()));
        }
    }
    Ok(index)
}

/// Multi-source traversal starts from persisted members; freshly connected nodes
/// attach to the nearest existing tree without rewriting its parent bindings.
fn forest(
    devices: &[Device],
    edges: &[Vec<usize>],
    known: &HashMap<&str, &Position>,
) -> Vec<Vec<(usize, Option<usize>)>> {
    let mut visited = vec![false; devices.len()];
    let mut roots: Vec<usize> = (0..devices.len()).collect();
    roots.sort_unstable_by_key(|&i| (devices[i].importance, std::cmp::Reverse(edges[i].len()), i));
    let mut output = Vec::new();
    for root in roots {
        if visited[root] {
            continue;
        }
        let mut members = Vec::new();
        let mut pending = vec![root];
        visited[root] = true;
        while let Some(i) = pending.pop() {
            members.push(i);
            for &next in edges[i].iter().rev() {
                if !visited[next] {
                    visited[next] = true;
                    pending.push(next);
                }
            }
        }
        let mut queue: VecDeque<_> = members
            .iter()
            .copied()
            .filter(|&i| known.contains_key(devices[i].id.as_str()))
            .map(|i| (i, None))
            .collect();
        let fresh = queue.is_empty();
        if queue.is_empty() {
            queue.push_back((root, None));
        }
        let mut assigned: HashSet<usize> = queue.iter().map(|(i, _)| *i).collect();
        let mut tree = Vec::with_capacity(members.len());
        while let Some((i, parent)) = queue.pop_front() {
            tree.push((i, parent));
            for &next in &edges[i] {
                if assigned.insert(next) {
                    queue.push_back((next, Some(i)));
                }
            }
        }
        // Select parents by breadth first distance, then pack each complete
        // subtree together. Breadth-first packing would strand infrastructure
        // at one end of the world and put its endpoint members far away.
        if fresh {
            let mut children = HashMap::<usize, Vec<usize>>::new();
            for &(i, parent) in &tree {
                if let Some(parent) = parent {
                    children.entry(parent).or_default().push(i);
                }
            }
            tree.clear();
            let mut pending = vec![(root, None)];
            while let Some((i, parent)) = pending.pop() {
                tree.push((i, parent));
                if let Some(children) = children.get(&i) {
                    pending.extend(children.iter().rev().map(|&child| (child, Some(i))));
                }
            }
        }
        output.push(tree);
    }
    output
}

/// Morton order keeps each parent's additions in nearby vacant cells. A cursor
/// per parent avoids repeatedly scanning an already-filled fanout. Refining a
/// full grid changes only the allocation resolution, never an existing point.
struct ComponentSlots {
    component: Cell,
    depth: u8,
    points: Vec<(u32, u32)>,
    occupied: BTreeSet<u64>,
    cursors: HashMap<String, u64>,
}

impl ComponentSlots {
    fn from_previous(previous: &[Position]) -> HashMap<Cell, Self> {
        let mut depths = HashMap::<Cell, u8>::new();
        for p in previous {
            depths
                .entry(p.component)
                .and_modify(|d| *d = (*d).max(p.placement_depth))
                .or_insert(p.placement_depth);
        }
        let mut slots: HashMap<Cell, Self> = depths
            .into_iter()
            .map(|(component, depth)| {
                (
                    component,
                    Self {
                        component,
                        depth,
                        points: Vec::new(),
                        occupied: BTreeSet::new(),
                        cursors: HashMap::new(),
                    },
                )
            })
            .collect();
        for p in previous {
            let slot = slots.get_mut(&p.component).expect("known component");
            slot.occupied.insert(slot.index(p.x, p.y));
            slot.points.push((p.x, p.y));
        }
        slots
    }

    fn index(&self, x: u32, y: u32) -> u64 {
        let (left, top) = self.component.origin();
        let shift = 24 - self.component.z - self.depth;
        morton_index((x - left) >> shift, (y - top) >> shift)
    }

    fn allocate(&mut self, parent: &Position) -> Result<(u32, u32, u8), Error> {
        while self.occupied.len() as u64 == 1u64 << (2 * self.depth) {
            if self.component.z + self.depth == 24 {
                return Err(Error::ExhaustedWorld);
            }
            self.depth += 1;
            self.occupied = self.points.iter().map(|&(x, y)| self.index(x, y)).collect();
            self.cursors.clear();
        }
        let capacity = 1u64 << (2 * self.depth);
        let start = self
            .cursors
            .get(&parent.id)
            .copied()
            .unwrap_or_else(|| self.index(parent.x, parent.y) + 1)
            % capacity;
        let mut candidate = start;
        for &used in self.occupied.range(start..) {
            if used > candidate {
                break;
            }
            candidate += 1;
        }
        if candidate == capacity {
            candidate = 0;
            for &used in self.occupied.range(..start) {
                if used > candidate {
                    break;
                }
                candidate += 1;
            }
        }
        self.occupied.insert(candidate);
        self.cursors.insert(parent.id.clone(), candidate + 1);
        let (x, y) = morton_point(self.component, self.depth, candidate);
        self.points.push((x, y));
        Ok((x, y, self.depth))
    }
}

#[derive(Default)]
struct ComponentCells {
    leaves: HashSet<Cell>,
    prefixes: HashSet<Cell>,
    occupied_area: u64,
}

impl ComponentCells {
    fn new(previous: &[Position]) -> Result<Self, Error> {
        let mut result = Self::default();
        for position in previous {
            let cell = position.component;
            if result.leaves.contains(&cell) {
                continue;
            }
            if result.prefixes.contains(&cell)
                || (0..cell.z).any(|z| result.leaves.contains(&cell.ancestor(z)))
            {
                return Err(Error::InvalidPosition(position.id.clone()));
            }
            result.insert(cell);
        }
        Ok(result)
    }

    fn insert(&mut self, cell: Cell) {
        if self.leaves.insert(cell) {
            self.occupied_area += 1u64 << (24 - 2 * cell.z);
            for z in 0..=cell.z {
                self.prefixes.insert(cell.ancestor(z));
            }
        }
    }

    fn reserve(&mut self, id: &str, initial_depth: u8, finest: u8) -> Result<Cell, Error> {
        let seed = hash(id);
        let finest = finest.min(12);
        if initial_depth <= finest
            && let Some(cell) = self.find(seed, initial_depth, finest, true)
        {
            self.insert(cell);
            return Ok(cell);
        }
        for z in (0..=finest).rev() {
            if let Some(cell) = self.find(seed, z, z, false) {
                self.insert(cell);
                return Ok(cell);
            }
        }
        Err(Error::ExhaustedWorld)
    }

    fn find(&self, seed: u64, from: u8, to: u8, area_limited: bool) -> Option<Cell> {
        let total = 1u64 << 24;
        for z in from..=to {
            let count = 1u64 << (2 * z);
            if area_limited && total / count > (total - self.occupied_area) / 4 {
                continue;
            }
            let samples = if area_limited { count.min(128) } else { count };
            for offset in 0..samples {
                let (x, y) = morton_xy(seed.wrapping_add(offset) % count);
                let cell = Cell { z, x, y };
                if !self.prefixes.contains(&cell)
                    && !(0..=z).any(|ancestor| self.leaves.contains(&cell.ancestor(ancestor)))
                {
                    return Some(cell);
                }
            }
        }
        None
    }
}

fn minimum_zoom(importance: u8) -> u8 {
    [0, 4, 8][usize::from(importance)]
}

fn depth_for(count: usize) -> u8 {
    let mut depth = 0;
    let mut capacity = 1usize;
    while capacity < count {
        depth += 1;
        capacity = capacity.saturating_mul(4);
    }
    depth
}

fn morton_xy(mut value: u64) -> (u32, u32) {
    let (mut x, mut y) = (0, 0);
    for bit in 0..24 {
        x |= (value as u32 & 1) << bit;
        value >>= 1;
        y |= (value as u32 & 1) << bit;
        value >>= 1;
    }
    (x, y)
}

pub(crate) fn morton_index(x: u32, y: u32) -> u64 {
    let mut index = 0;
    for bit in 0..24 {
        index |= (u64::from(x >> bit) & 1) << (2 * bit);
        index |= (u64::from(y >> bit) & 1) << (2 * bit + 1);
    }
    index
}

fn morton_point(component: Cell, depth: u8, slot: u64) -> (u32, u32) {
    let (x, y) = morton_xy(slot);
    let step = component.width() >> depth;
    let (left, top) = component.origin();
    (left + x * step + step / 2, top + y * step + step / 2)
}

fn point_key(x: u32, y: u32) -> u64 {
    (u64::from(x) << 32) | u64::from(y)
}

fn hash(id: &str) -> u64 {
    let digest = Sha256::digest(id.as_bytes());
    u64::from_be_bytes(digest[..8].try_into().expect("eight hash bytes"))
}
