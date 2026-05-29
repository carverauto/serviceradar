#[allow(clippy::large_enum_variant)]
pub mod netprobe {
    include!(concat!(
        env!("OUT_DIR"),
        "/serviceradar.agent.netprobe.v1.rs"
    ));
}
