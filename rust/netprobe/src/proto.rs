// Generated prost types. The binary's `mod proto` is private, so rustc treats
// unused `pub` messages as dead_code. FingerprintEventBatch / DpiEventBatch /
// ProcessSnapshotBatch are constructed by the control-plane ingest path, not
// by this sidecar, which still emits per-event NetprobeFrames.
#[allow(clippy::large_enum_variant, dead_code)]
pub mod netprobe {
    include!(concat!(
        env!("OUT_DIR"),
        "/serviceradar.agent.netprobe.v1.rs"
    ));
}
