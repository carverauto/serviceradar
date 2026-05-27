pub mod netprobe {
    include!(concat!(
        env!("OUT_DIR"),
        "/serviceradar.agent.netprobe.v1.rs"
    ));
}
