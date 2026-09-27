use serviceradar_topology_atlas::{Device, Relation};

pub const COUNT: usize = 1_000_000;

pub fn hierarchy() -> (Vec<Device>, Vec<Relation>) {
    // Generated independently: 1,000 invented sites, each with a core, ten
    // infrastructure devices and invented endpoint members. A second relation
    // per member represents redundant access. No live topology is an input.
    let mut nodes = Vec::with_capacity(COUNT + COUNT / 100);
    let mut links = Vec::with_capacity(COUNT * 2 + COUNT / 100);
    for i in 0..COUNT {
        let within = i % 1000;
        nodes.push(device(
            &format!("sr:node-{i:07}.example.test"),
            if within == 0 {
                0
            } else if within <= 10 {
                1
            } else {
                2
            },
        ));
    }
    for i in 0..COUNT {
        let base = i / 1000 * 1000;
        let first = if i % 1000 == 0 {
            base + 1
        } else if i % 1000 <= 10 {
            base
        } else {
            base + 1 + (i % 10)
        };
        let second = base + 1 + ((i + 1) % 10);
        links.push(relation(&nodes[i].id, &nodes[first].id));
        links.push(relation(&nodes[i].id, &nodes[second].id));
    }
    (nodes, links)
}

fn device(id: &str, importance: u8) -> Device {
    Device {
        id: id.into(),
        label: id.strip_prefix("sr:").unwrap_or(id).into(),
        importance,
    }
}

fn relation(source: &str, target: &str) -> Relation {
    Relation {
        id: format!("{source}/{target}"),
        source: source.into(),
        target: target.into(),
    }
}
