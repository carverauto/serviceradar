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
        verdicts.extend(c3_gateway_shared_fate(ctx));
        verdicts.extend(c4_management_unobservable(ctx));
        Ok(verdicts)
    }
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
        verdicts.push(Verdict {
            entity_id: gateway.to_string(),
            classification: Classification::RootCause,
            reason: format!(
                "{} devices observing through gateway {} are simultaneously unavailable",
                devices.len(),
                gateway
            ),
        });
        for device in devices {
            verdicts.push(Verdict {
                entity_id: device.uid.clone(),
                classification: Classification::Affected,
                reason: format!("unavailable; shares root-cause gateway {gateway}"),
            });
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
    let availability: HashMap<&str, Option<bool>> = ctx
        .devices
        .iter()
        .map(|d| (d.uid.as_str(), d.is_available))
        .collect();

    let mut verdicts = Vec::new();
    for edge in &ctx.edges {
        // `src` is managed by `dst`; if the manager `dst` is unavailable, the
        // managed device `src` is unobservable through it.
        if edge.kind == EdgeKind::ManagedBy
            && availability.get(edge.dst.as_str()) == Some(&Some(false))
        {
            verdicts.push(Verdict {
                entity_id: edge.src.clone(),
                classification: Classification::Unknown,
                reason: format!(
                    "manager {} is unavailable; availability is unobservable, not failed",
                    edge.dst
                ),
            });
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
            risk_score: None,
            gateway_id: gateway.map(|g| g.to_string()),
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
            services: vec![],
            edges: vec![],
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
            services: vec![],
            edges: vec![],
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
            services: vec![],
            edges: vec![],
        };
        let verdicts = reasoner.evaluate(&ctx).expect("evaluate");
        assert!(verdicts
            .iter()
            .any(|v| v.entity_id == "sr:gw:1" && v.classification == Classification::RootCause));
    }

    fn managed_by(child: &str, manager: &str) -> TopologyEdge {
        TopologyEdge {
            src: child.to_string(),
            dst: manager.to_string(),
            kind: EdgeKind::ManagedBy,
        }
    }

    #[test]
    fn c4_marks_devices_behind_a_dead_manager_unknown() {
        let ctx = Context {
            devices: vec![
                device("sr:device:mgr", Some(false), None),
                device("sr:device:child", Some(false), None),
            ],
            services: vec![],
            edges: vec![managed_by("sr:device:child", "sr:device:mgr")],
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
            services: vec![],
            edges: vec![managed_by("sr:device:child", "sr:device:mgr")],
        };
        assert!(c4_management_unobservable(&ctx).is_empty());
    }
}
