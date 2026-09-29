mod hierarchy;

use serviceradar_topology_atlas::reconcile;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::time::Instant;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let output = std::env::args()
        .nth(1)
        .ok_or("expected fixture output path")?;
    let (nodes, relations) = hierarchy::hierarchy();
    let started = Instant::now();
    let positions = reconcile(nodes, &relations, &[])?;
    let mut writer = BufWriter::new(File::create(output)?);
    writeln!(writer, "layout_ms\t{}", started.elapsed().as_millis())?;
    // IDs and labels come solely from the fixture above and contain no TSV
    // delimiters. Stream the intermediate input; never materialize a live graph.
    for p in positions {
        writeln!(
            writer,
            "p\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            p.id,
            p.label,
            p.x,
            p.y,
            p.min_zoom,
            p.parent_id.unwrap_or_default(),
            p.component_id,
            p.component.z,
            p.component.x,
            p.component.y,
            p.placement_depth
        )?;
    }
    for r in relations {
        writeln!(writer, "r\t{}\t{}\t{}", r.id, r.source, r.target)?;
    }
    writer.flush()?;
    Ok(())
}
