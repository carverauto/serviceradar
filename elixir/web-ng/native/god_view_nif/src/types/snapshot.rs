//! The input frame consumed by the Arrow snapshot encoder.
//!
//! Every column the encoder writes travels in this one payload, so the encoder
//! takes a single decoded value instead of a long positional argument list.

use rustler::NifMap;

/// A complete God View topology frame handed to the Arrow snapshot encoder.
///
/// Decoded directly from the Elixir map passed to `encode_snapshot/1`. The
/// runtime graph NIF builds one by hand from its cached links, which is why the
/// per-edge side tables (`edge_directional`, `edge_details`) are allowed to be
/// shorter than `edges`: the encoder falls back to neutral defaults per row.
#[derive(NifMap)]
pub(crate) struct EncodeSnapshotPayload {
    /// Wire format version the frontend decoder negotiates against.
    pub(crate) schema_version: u32,
    /// Monotonic revision of the topology state this frame captures.
    pub(crate) revision: u64,
    /// Node rows: `(x, y, state, label, pps, oper_up, details_json)`.
    pub(crate) nodes: Vec<(u16, u16, u8, String, u32, u8, String)>,
    /// Edge rows: `(source, target, pps, flow_bps, capacity_bps, label, telemetry_eligible)`.
    pub(crate) edges: Vec<(u16, u16, u32, u64, u64, String, u8)>,
    /// Per-edge classification: `(topology_class, protocol, evidence_class)`.
    pub(crate) edge_meta: Vec<(String, String, String)>,
    /// Per-edge directional telemetry: `(pps_ab, pps_ba, bps_ab, bps_ba)`.
    pub(crate) edge_directional: Vec<(u32, u32, u64, u64)>,
    /// Per-edge raw JSON detail blobs surfaced on inspection in the UI.
    pub(crate) edge_details: Vec<String>,
    /// Byte length of the serialized root-cause bitmap sent alongside this frame.
    pub(crate) root_bitmap_bytes: u32,
    /// Byte length of the serialized affected-node bitmap sent alongside this frame.
    pub(crate) affected_bitmap_bytes: u32,
    /// Byte length of the serialized healthy-node bitmap sent alongside this frame.
    pub(crate) healthy_bitmap_bytes: u32,
    /// Byte length of the serialized unknown-node bitmap sent alongside this frame.
    pub(crate) unknown_bitmap_bytes: u32,
}
