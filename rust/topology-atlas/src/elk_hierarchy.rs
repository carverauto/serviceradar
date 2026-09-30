//! Compose bounded executions of the existing ELK radial engine into one world.
//! Partition summaries reserve the complete child layout's envelope; geometry
//! is authored once during publication, never independently inside a tile.
use std::collections::{HashMap, HashSet, VecDeque};

use serde_json::json;

use crate::{Cell, Error, elk::Elk};

const BATCH: usize = 512;
const GLYPH: f64 = 112.0;

struct Chunk {
    members: Vec<usize>,
    edges: Vec<(usize, usize)>,
    frontier: HashSet<usize>,
}

struct Layout {
    width: f64,
    height: f64,
    points: Vec<(usize, f64, f64)>,
    children: Vec<(usize, f64, f64)>,
}

pub(crate) struct Drawing {
    layouts: HashMap<usize, Layout>,
}

pub(crate) fn compose(tree: &[(usize, Option<usize>)], engine: &Elk) -> Result<Drawing, Error> {
    let local: HashMap<_, _> = tree
        .iter()
        .enumerate()
        .map(|(n, (id, _))| (*id, n))
        .collect();
    let mut children = vec![Vec::new(); tree.len()];
    for (n, (_, parent)) in tree.iter().enumerate() {
        if let Some(parent) = parent {
            children[local[parent]].push(n);
        }
    }
    // Bound even a million-leaf star. These layout-only grouping nodes carry
    // child envelopes, never inventory identity or aggregate membership.
    for node in 0..tree.len() {
        let mut level = std::mem::take(&mut children[node]);
        while level.len() >= BATCH {
            let mut next = Vec::new();
            for group in level.chunks(BATCH - 1) {
                next.push(children.len());
                children.push(group.to_vec());
            }
            level = next;
        }
        children[node] = level;
    }
    let mut chunks = Vec::new();
    let mut pending = VecDeque::from([0]);
    while let Some(root) = pending.pop_front() {
        let mut chunk = Chunk {
            members: vec![root],
            edges: Vec::new(),
            frontier: HashSet::new(),
        };
        let mut cursor = 0;
        while cursor < chunk.members.len() {
            let node = chunk.members[cursor];
            if chunk.members.len() + children[node].len() <= BATCH {
                for child in &children[node] {
                    chunk.members.push(*child);
                    chunk.edges.push((node, *child));
                }
            } else if !children[node].is_empty() {
                chunk.frontier.insert(node);
                pending.push_back(node);
            }
            cursor += 1;
        }
        chunks.push(chunk);
    }
    let mut layouts: HashMap<usize, Layout> = HashMap::new();
    for chunk in chunks.into_iter().rev() {
        let root = chunk.members[0];
        let nodes: Vec<_> = chunk.members.iter().map(|node| {
            let layout = layouts.get(node).filter(|_| chunk.frontier.contains(node));
            json!({"id": node.to_string(), "width": layout.map_or(GLYPH, |l| l.width), "height": layout.map_or(GLYPH, |l| l.height)})
        }).collect();
        let edges: Vec<_> = chunk.edges.iter().map(|(a, b)| json!({"id": format!("{a}/{b}"), "sources": [a.to_string()], "targets": [b.to_string()]})).collect();
        let positions = engine.layout(&nodes, &edges)?;
        if positions.len() != chunk.members.len() {
            return Err(Error::LayoutUnavailable);
        }
        let mut points = Vec::new();
        let mut child_offsets = Vec::new();
        let mut bounds = (
            f64::INFINITY,
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::NEG_INFINITY,
        );
        for (node, x, y) in positions {
            let (width, height) = if chunk.frontier.contains(&node) {
                let layout = layouts.get(&node).ok_or(Error::LayoutUnavailable)?;
                let dimensions = (layout.width, layout.height);
                child_offsets.push((node, x - layout.width / 2.0, y - layout.height / 2.0));
                dimensions
            } else {
                if node < tree.len() {
                    points.push((tree[node].0, x, y));
                }
                (GLYPH, GLYPH)
            };
            bounds.0 = bounds.0.min(x - width / 2.0);
            bounds.1 = bounds.1.min(y - height / 2.0);
            bounds.2 = bounds.2.max(x + width / 2.0);
            bounds.3 = bounds.3.max(y + height / 2.0);
        }
        for (_, x, y) in points.iter_mut().chain(child_offsets.iter_mut()) {
            *x -= bounds.0;
            *y -= bounds.1;
        }
        layouts.insert(
            root,
            Layout {
                width: bounds.2 - bounds.0,
                height: bounds.3 - bounds.1,
                points,
                children: child_offsets,
            },
        );
    }
    Ok(Drawing { layouts })
}

pub(crate) fn finest_cell(drawing: &Drawing, expected: usize) -> Result<u8, Error> {
    for z in (0..=12).rev() {
        if project(drawing, Cell { z, x: 0, y: 0 }, expected).is_ok() {
            return Ok(z);
        }
    }
    Err(Error::ExhaustedWorld)
}

pub(crate) fn project(
    drawing: &Drawing,
    component: Cell,
    expected: usize,
) -> Result<HashMap<usize, (u32, u32)>, Error> {
    let root = drawing.layouts.get(&0).ok_or(Error::LayoutUnavailable)?;
    let width = f64::from(component.width());
    let scale = (width - 2.0) / root.width.max(root.height).max(1.0);
    let (left, top) = component.origin();
    let offset_x = (width - root.width * scale) / 2.0;
    let offset_y = (width - root.height * scale) / 2.0;
    let mut occupied = HashSet::new();
    let mut result = HashMap::new();
    // Apply accumulated offsets once per device, rather than copying each
    // descendant's geometry through every ancestor in a deep hierarchy.
    let mut pending = vec![(0usize, 0.0, 0.0)];
    let mut seen = HashSet::new();
    while let Some((node, dx, dy)) = pending.pop() {
        if !seen.insert(node) {
            return Err(Error::LayoutUnavailable);
        }
        let layout = drawing.layouts.get(&node).ok_or(Error::LayoutUnavailable)?;
        for &(id, x, y) in &layout.points {
            let x = left + (offset_x + (x + dx) * scale).round() as u32;
            let y = top + (offset_y + (y + dy) * scale).round() as u32;
            if !component.contains(x, y) || !occupied.insert((x, y)) {
                return Err(Error::ExhaustedWorld);
            }
            result.insert(id, (x, y));
        }
        pending.extend(
            layout
                .children
                .iter()
                .map(|&(id, x, y)| (id, x + dx, y + dy)),
        );
    }
    if result.len() != expected || seen.len() != drawing.layouts.len() {
        return Err(Error::LayoutUnavailable);
    }
    Ok(result)
}
