//! The reasoner — a DeepCausality `CausaloidGraph` evaluated over an
//! `ultragraph` `CsmGraph`.
//!
//! TODO(1.3): build the graph layer on `ultragraph` 0.9 (`CsmGraph` CSR;
//! `freeze()` before each tick, `unfreeze()` only on real topology change) and
//! wrap it in a DeepCausality `CausaloidGraph`.
//! TODO(1.4): implement causaloids C1–C13. Six are direct `ultragraph` 0.9
//! library calls — `articulation_points`/`bridges` (C5/C5b), `is_reachable`
//! (C4/C7/C8), `pathway_betweenness_centrality` (C9).
//! TODO(1.5): compose per-device risk (`risk_score` + `pkg_*` scalars) into
//! C5/C7/C10 as numeric observations.

use std::collections::HashMap;

use crate::domain_model::{Context, Device, EdgeKind};
use crate::error::Result;

/// A gateway is flagged as a shared-fate root cause when at least this many of
/// the devices that observe through it are simultaneously unavailable (C3).
const GATEWAY_SHARED_FATE_THRESHOLD: usize = 2;

/// Verdict classification — maps cleanly onto the God-View 4-bucket render
/// (`root_cause` / `affected` / `healthy` / `unknown`, `GodViewSnapshot`
/// schema_version 2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Classification {
    /// Identified root cause.
    RootCause,
    /// Predicted/observed to be affected by a root cause.
    Affected,
    /// Healthy.
    Healthy,
    /// State cannot be determined (e.g. unobservable).
    Unknown,
}

/// A causal verdict for a single entity.
#[derive(Debug, Clone)]
pub struct Verdict {
    /// Canonical `sr:`-prefixed entity id the verdict applies to.
    pub entity_id: String,
    /// The causal classification.
    pub classification: Classification,
    /// Human-readable explanation (drives the God-View explainability surface).
    pub reason: String,
    /// Predicted severity on a 0..=100 scale. Seeded from the classification and
    /// raised by per-device risk composition for C5/C7/C10 (task 1.5).
    pub severity: u8,
}

impl Verdict {
    /// Construct a verdict, seeding `severity` from the classification.
    pub fn new(
        entity_id: impl Into<String>,
        classification: Classification,
        reason: impl Into<String>,
    ) -> Self {
        Self {
            entity_id: entity_id.into(),
            classification,
            reason: reason.into(),
            severity: base_severity(classification),
        }
    }

    /// Raise the predicted severity to at least `severity` (clamped to 100),
    /// never lowering it. Used by risk composition (task 1.5) to amplify — not
    /// override — the structural conclusion.
    pub fn raise_severity_to(mut self, severity: u8) -> Self {
        self.severity = self.severity.max(severity.min(100));
        self
    }
}

/// Baseline predicted severity for a classification (0..=100), before any
/// risk composition.
fn base_severity(classification: Classification) -> u8 {
    match classification {
        Classification::RootCause => 80,
        Classification::Affected => 50,
        Classification::Unknown => 30,
        Classification::Healthy => 0,
    }
}

/// Index device availability by canonical uid for O(1) lookups across causaloids.
fn availability_map(ctx: &Context) -> HashMap<&str, Option<bool>> {
    ctx.devices
        .iter()
        .map(|d| (d.uid.as_str(), d.is_available))
        .collect()
}

/// The DeepCausality reasoner.
#[derive(Default)]
pub struct Reasoner {
    // TODO(1.3): CausaloidGraph + the frozen ultragraph CsmGraph.
}

impl Reasoner {
    /// Construct a reasoner. TODO(1.3): build the CausaloidGraph.
    pub fn new() -> Self {
        Self::default()
    }

    /// Run one reasoning tick over the hydrated context, evaluating the
    /// implemented causaloids and collecting verdicts.
    ///
    /// Implemented: C3 (gateway/agent shared-fate root cause). TODO(1.3/1.4/1.5):
    /// the remaining causaloids (graph + virtualization + temporal) and risk
    /// composition, on the `ultragraph` 0.9 graph layer.
    pub fn evaluate(&self, ctx: &Context) -> Result<Vec<Verdict>> {
        let mut verdicts = Vec::new();
        verdicts.extend(c1_containment_cascade(ctx));
        verdicts.extend(c2_datastore_cascade(ctx));
        verdicts.extend(c3_gateway_shared_fate(ctx));
        verdicts.extend(c4_management_unobservable(ctx));
        Ok(verdicts)
    }
}

/// C1 — virtualization containment cascade.
///
/// When a virtualization host (the `src` of a `CONTAINS` edge) is unavailable,
/// the guests it contains (`dst`) are predicted to be affected by the host
/// failure rather than treated as independently down.
fn c1_containment_cascade(ctx: &Context) -> Vec<Verdict> {
    let availability = availability_map(ctx);
    let mut verdicts = Vec::new();
    for edge in &ctx.edges {
        if edge.kind == EdgeKind::Contains
            && availability.get(edge.src.as_str()) == Some(&Some(false))
        {
            verdicts.push(Verdict::new(
                edge.dst.clone(),
                Classification::Affected,
                format!(
                    "virtualization host {} is unavailable; contained guest is affected",
                    edge.src
                ),
            ));
        }
    }
    verdicts
}

/// C2 — datastore degradation cascade.
///
/// When a datastore (the `dst` of a `BACKED_BY` edge) is unavailable/degraded,
/// the guests whose virtual disks it backs (`src`) are predicted to be affected.
fn c2_datastore_cascade(ctx: &Context) -> Vec<Verdict> {
    let availability = availability_map(ctx);
    let mut verdicts = Vec::new();
    for edge in &ctx.edges {
        if edge.kind == EdgeKind::BackedBy
            && availability.get(edge.dst.as_str()) == Some(&Some(false))
        {
            verdicts.push(Verdict::new(
                edge.src.clone(),
                Classification::Affected,
                format!(
                    "datastore {} is degraded; guest disk backed by it is affected",
                    edge.dst
                ),
            ));
        }
    }
    verdicts
}

/// C3 — gateway/agent shared-fate root-cause classification.
///
/// When `GATEWAY_SHARED_FATE_THRESHOLD`+ devices that observe through the same
/// gateway flip unavailable together, the shared gateway is the likelier root
/// cause than each device independently: emit `RootCause` for the gateway and
/// `Affected` for each device that shares its fate.
fn c3_gateway_shared_fate(ctx: &Context) -> Vec<Verdict> {
    let mut unavailable_by_gateway: HashMap<&str, Vec<&Device>> = HashMap::new();
    for device in &ctx.devices {
        if device.is_available == Some(false) {
            if let Some(gateway) = device.gateway_id.as_deref() {
                unavailable_by_gateway
                    .entry(gateway)
                    .or_default()
                    .push(device);
            }
        }
    }

    let mut verdicts = Vec::new();
    for (gateway, devices) in unavailable_by_gateway {
        if devices.len() < GATEWAY_SHARED_FATE_THRESHOLD {
            continue;
        }
        verdicts.push(Verdict::new(
            gateway.to_string(),
            Classification::RootCause,
            format!(
                "{} devices observing through gateway {} are simultaneously unavailable",
                devices.len(),
                gateway
            ),
        ));
        for device in devices {
            verdicts.push(Verdict::new(
                device.uid.clone(),
                Classification::Affected,
                format!("unavailable; shares root-cause gateway {gateway}"),
            ));
        }
    }
    verdicts
}

/// C4 — management-unobservable suppression.
///
/// A device whose manager (via `MANAGED_BY`) is unavailable cannot be observed
/// through that manager, so its availability is `Unknown` rather than failed —
/// suppressing false "down" classifications for devices behind a dead manager.
fn c4_management_unobservable(ctx: &Context) -> Vec<Verdict> {
    let availability = availability_map(ctx);
    let mut verdicts = Vec::new();
    for edge in &ctx.edges {
        // `src` is managed by `dst`; if the manager `dst` is unavailable, the
        // managed device `src` is unobservable through it.
        if edge.kind == EdgeKind::ManagedBy
            && availability.get(edge.dst.as_str()) == Some(&Some(false))
        {
            verdicts.push(Verdict::new(
                edge.src.clone(),
                Classification::Unknown,
                format!(
                    "manager {} is unavailable; availability is unobservable, not failed",
                    edge.dst
                ),
            ));
        }
    }
    verdicts
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain_model::{Context, Device, EdgeKind, TopologyEdge};

    fn device(uid: &str, available: Option<bool>, gateway: Option<&str>) -> Device {
        Device {
            uid: uid.to_string(),
            is_available: available,
            is_managed: Some(true),
            gateway_id: gateway.map(|g| g.to_string()),
            ..Default::default()
        }
    }

    fn classification_of<'a>(verdicts: &'a [Verdict], entity: &str) -> Option<&'a Classification> {
        verdicts
            .iter()
            .find(|v| v.entity_id == entity)
            .map(|v| &v.classification)
    }

    #[test]
    fn c3_flags_shared_gateway_as_root_cause() {
        let ctx = Context {
            devices: vec![
                device("sr:device:a", Some(false), Some("sr:gw:1")),
                device("sr:device:b", Some(false), Some("sr:gw:1")),
                device("sr:device:c", Some(true), Some("sr:gw:1")),
            ],
            ..Default::default()
        };

        let verdicts = c3_gateway_shared_fate(&ctx);
        assert_eq!(
            classification_of(&verdicts, "sr:gw:1"),
            Some(&Classification::RootCause)
        );
        assert_eq!(
            classification_of(&verdicts, "sr:device:a"),
            Some(&Classification::Affected)
        );
        assert_eq!(
            classification_of(&verdicts, "sr:device:b"),
            Some(&Classification::Affected)
        );
        // the healthy device on the same gateway is not implicated
        assert_eq!(classification_of(&verdicts, "sr:device:c"), None);
    }

    #[test]
    fn c3_ignores_below_threshold_and_gatewayless() {
        let ctx = Context {
            devices: vec![
                device("sr:device:a", Some(false), Some("sr:gw:1")),
                device("sr:device:x", Some(false), None),
            ],
            ..Default::default()
        };
        assert!(c3_gateway_shared_fate(&ctx).is_empty());
    }

    #[test]
    fn reasoner_evaluate_runs_c3() {
        let reasoner = Reasoner::new();
        let ctx = Context {
            devices: vec![
                device("sr:device:a", Some(false), Some("sr:gw:1")),
                device("sr:device:b", Some(false), Some("sr:gw:1")),
            ],
            ..Default::default()
        };
        let verdicts = reasoner.evaluate(&ctx).expect("evaluate");
        assert!(verdicts
            .iter()
            .any(|v| v.entity_id == "sr:gw:1" && v.classification == Classification::RootCause));
    }

    fn managed_by(child: &str, manager: &str) -> TopologyEdge {
        TopologyEdge::new(child, manager, EdgeKind::ManagedBy)
    }

    #[test]
    fn c4_marks_devices_behind_a_dead_manager_unknown() {
        let ctx = Context {
            devices: vec![
                device("sr:device:mgr", Some(false), None),
                device("sr:device:child", Some(false), None),
            ],
            edges: vec![managed_by("sr:device:child", "sr:device:mgr")],
            ..Default::default()
        };
        let verdicts = c4_management_unobservable(&ctx);
        assert_eq!(
            classification_of(&verdicts, "sr:device:child"),
            Some(&Classification::Unknown)
        );
    }

    #[test]
    fn c4_no_verdict_when_manager_available() {
        let ctx = Context {
            devices: vec![
                device("sr:device:mgr", Some(true), None),
                device("sr:device:child", Some(false), None),
            ],
            edges: vec![managed_by("sr:device:child", "sr:device:mgr")],
            ..Default::default()
        };
        assert!(c4_management_unobservable(&ctx).is_empty());
    }

    fn contains(host: &str, guest: &str) -> TopologyEdge {
        TopologyEdge::new(host, guest, EdgeKind::Contains)
    }

    fn backed_by(guest: &str, datastore: &str) -> TopologyEdge {
        TopologyEdge::new(guest, datastore, EdgeKind::BackedBy)
    }

    #[test]
    fn c1_cascades_host_failure_to_contained_guests() {
        let ctx = Context {
            devices: vec![
                device("sr:device:host", Some(false), None),
                device("sr:device:guest-a", Some(true), None),
                device("sr:device:guest-b", Some(true), None),
            ],
            edges: vec![
                contains("sr:device:host", "sr:device:guest-a"),
                contains("sr:device:host", "sr:device:guest-b"),
            ],
            ..Default::default()
        };
        let verdicts = c1_containment_cascade(&ctx);
        assert_eq!(
            classification_of(&verdicts, "sr:device:guest-a"),
            Some(&Classification::Affected)
        );
        assert_eq!(
            classification_of(&verdicts, "sr:device:guest-b"),
            Some(&Classification::Affected)
        );
    }

    #[test]
    fn c1_no_cascade_when_host_available() {
        let ctx = Context {
            devices: vec![
                device("sr:device:host", Some(true), None),
                device("sr:device:guest-a", Some(true), None),
            ],
            edges: vec![contains("sr:device:host", "sr:device:guest-a")],
            ..Default::default()
        };
        assert!(c1_containment_cascade(&ctx).is_empty());
    }

    #[test]
    fn c2_cascades_datastore_degradation_to_guest_disks() {
        let ctx = Context {
            devices: vec![
                device("sr:device:ds1", Some(false), None),
                device("sr:device:guest-a", Some(true), None),
            ],
            edges: vec![backed_by("sr:device:guest-a", "sr:device:ds1")],
            ..Default::default()
        };
        assert_eq!(
            classification_of(&c2_datastore_cascade(&ctx), "sr:device:guest-a"),
            Some(&Classification::Affected)
        );
    }

    #[test]
    fn c2_no_cascade_when_datastore_healthy() {
        let ctx = Context {
            devices: vec![
                device("sr:device:ds1", Some(true), None),
                device("sr:device:guest-a", Some(true), None),
            ],
            edges: vec![backed_by("sr:device:guest-a", "sr:device:ds1")],
            ..Default::default()
        };
        assert!(c2_datastore_cascade(&ctx).is_empty());
    }
}
