//! Portable codec fixtures are generated from invented ordinal sets by the Rust
//! serializer, then decoded independently by roaring-wasm's browser tests.
use roaring::RoaringBitmap;
use std::io::Write;
fn main() -> std::io::Result<()> {
    let path = std::env::args().nth(1).expect("output path");
    let dense: RoaringBitmap = (1..=100_000).collect();
    let mut run = dense.clone();
    run.optimize();
    assert!(run.statistics().n_run_containers > 0);
    let mut run_mixed = run.clone();
    run_mixed.extend([2_147_483_648, u32::MAX]);
    let sections = [
        ("empty", RoaringBitmap::new()),
        (
            "sparse",
            [1, 65_536, 2_147_483_648, u32::MAX].into_iter().collect(),
        ),
        ("dense", dense),
        ("run", run),
        ("run_mixed", run_mixed),
    ];
    let mut output = std::fs::File::create(path)?;
    output.write_all(&(sections.len() as u16).to_le_bytes())?;
    for (name, bitmap) in sections {
        let mut bytes = Vec::with_capacity(bitmap.serialized_size());
        bitmap.serialize_into(&mut bytes)?;
        output.write_all(&(name.len() as u16).to_le_bytes())?;
        output.write_all(name.as_bytes())?;
        output.write_all(&(bytes.len() as u32).to_le_bytes())?;
        output.write_all(&bytes)?;
    }
    Ok(())
}
