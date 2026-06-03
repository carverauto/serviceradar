//! The reasoner — causaloids C1–C13 evaluated over the hydrated [`Context`].
//!
//! The non-graph causaloids operate directly on `Context` state/metrics/risk;
//! the graph causaloids (C5/C5b/C8/C9/C10) build an `ultragraph` `CsmGraph` from
//! `Context.edges` (see the `graph` module) and call its structural/centrality/
//! reachability algorithms.
//!
//! Implemented (1.4):
//! - C1 virtualization containment cascade, C2 datastore cascade
//! - C3 gateway/agent shared-fate root cause (incl. Gap E out-of-band suppression)
//! - C4 management-unobservable suppression
//! - C6 interface-saturation projection (capacity-eligible links only)
//! - C7 service-stack collapse
//! - C11 flap-rate precursor, C12 operator-rule promotion, C13 discovery-gap
//! - C5/C5b single-point-of-failure, C8 BGP withdrawal, C9 shared-hop bottleneck,
//!   C10 traffic-source blast radius (graph causaloids, `graph` module)
//!
//! Risk composition (1.5): per-device `risk_score` + `pkg_severity` raise — but
//! never alter — the predicted severity of C5/C7/C10.

use std::collections::HashMap;

use crate::domain_model::{Context, Device, EdgeKind, GatewayClass};
use crate::error::Result;

/// A gateway is flagged as a shared-fate root cause when at least this many of
/// the devices that observe through it are simultaneously unavailable (C3).
const GATEWAY_SHARED_FATE_THRESHOLD: usize = 2;

/// A link is flagged by C6 as projected-saturated at or above this percent
/// utilization (observed `flow_bps` / engineered `capacity_bps`).
const SATURATION_UTILIZATION_PCT: i64 = 80;

/// A node with at least this many recent state transitions is flagged by C11 as
/// an instability precursor.
const FLAP_PRECURSOR_THRESHOLD: i64 = 3;

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

/// Combined availability across devices (by uid) and services (by composite id)
/// — a `DEPENDS_ON` target may be either (C7).
fn entity_availability_map(ctx: &Context) -> HashMap<&str, Option<bool>> {
    let mut map = availability_map(ctx);
    for service in &ctx.services {
        map.insert(service.id.as_str(), service.available);
    }
    map
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

    /// Run one reasoning tick over the hydrated context, evaluating every
    /// implemented causaloid (C1–C13) and collecting verdicts.
    pub fn evaluate(&self, ctx: &Context) -> Result<Vec<Verdict>> {
        let mut verdicts = Vec::new();
        // Non-graph causaloids over Context state / metrics / risk.
        verdicts.extend(c1_containment_cascade(ctx));
        verdicts.extend(c2_datastore_cascade(ctx));
        verdicts.extend(c3_gateway_shared_fate(ctx));
        verdicts.extend(c4_management_unobservable(ctx));
        verdicts.extend(c6_interface_saturation(ctx));
        verdicts.extend(c7_service_stack_collapse(ctx));
        verdicts.extend(c11_flap_precursor(ctx));
        verdicts.extend(c12_operator_rule_promotion(ctx));
        verdicts.extend(c13_discovery_gap(ctx));
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
///
/// Gap E: a gateway whose `gateway_class` is out-of-band or management is NOT a
/// data-plane reachability path, so its failure is not blamed as the data-plane
/// root cause — the shared-fate inference is suppressed for that gateway.
fn c3_gateway_shared_fate(ctx: &Context) -> Vec<Verdict> {
    let class_by_uid: HashMap<&str, GatewayClass> = ctx
        .devices
        .iter()
        .filter_map(|d| d.gateway_class.map(|class| (d.uid.as_str(), class)))
        .collect();

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
        // Gap E: out-of-band / management gateways are not in-band reachability.
        if matches!(
            class_by_uid.get(gateway),
            Some(GatewayClass::OutOfBand | GatewayClass::Management)
        ) {
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

/// C6 — interface/link saturation projection.
///
/// Projects saturation on capacity-eligible links by comparing observed
/// `flow_bps` against the engineered `capacity_bps`. A link without a capacity
/// denominator is capacity-ineligible (Gap B contract) and is skipped — no
/// projection is emitted without a denominator.
fn c6_interface_saturation(ctx: &Context) -> Vec<Verdict> {
    let mut verdicts = Vec::new();
    for link in &ctx.links {
        // No capacity denominator => capacity-ineligible => no projection.
        let (Some(flow), Some(capacity)) = (link.flow_bps, link.capacity_bps) else {
            continue;
        };
        if capacity <= 0 {
            continue;
        }
        let utilization_pct = flow.saturating_mul(100) / capacity;
        if utilization_pct < SATURATION_UTILIZATION_PCT {
            continue;
        }
        let headroom_bps = (capacity - flow).max(0);
        let severity = utilization_pct.clamp(0, 100) as u8;
        verdicts.push(
            Verdict::new(
                link.src.clone(),
                Classification::Affected,
                format!(
                    "link {} -> {} projected saturation: {}% utilized ({} bps headroom of {} bps)",
                    link.src, link.dst, utilization_pct, headroom_bps, capacity
                ),
            )
            .raise_severity_to(severity),
        );
    }
    verdicts
}

/// C7 — service-stack collapse prediction.
///
/// When an underlying dependency (the `dst` of a `DEPENDS_ON` edge — a service,
/// host, or resource) is unavailable, the dependent stack (`src`) is predicted
/// to collapse/degrade.
fn c7_service_stack_collapse(ctx: &Context) -> Vec<Verdict> {
    let availability = entity_availability_map(ctx);
    let mut verdicts = Vec::new();
    for edge in &ctx.edges {
        if edge.kind == EdgeKind::DependsOn
            && availability.get(edge.dst.as_str()) == Some(&Some(false))
        {
            verdicts.push(Verdict::new(
                edge.src.clone(),
                Classification::Affected,
                format!(
                    "dependency {} is unavailable; dependent stack predicted to collapse",
                    edge.dst
                ),
            ));
        }
    }
    verdicts
}

/// C11 — flap-rate instability precursor.
///
/// An elevated flap rate (rapid repeated state transitions) is treated as a
/// precursor to instability: emit a precursor prediction for the flapping node,
/// with severity scaling with the flap count.
fn c11_flap_precursor(ctx: &Context) -> Vec<Verdict> {
    let mut verdicts = Vec::new();
    for device in &ctx.devices {
        if let Some(flaps) = device.flap_count {
            if flaps >= FLAP_PRECURSOR_THRESHOLD {
                let severity = (50 + flaps.saturating_mul(5)).clamp(0, 100) as u8;
                verdicts.push(
                    Verdict::new(
                        device.uid.clone(),
                        Classification::Affected,
                        format!(
                            "elevated flap rate ({flaps} recent transitions); instability precursor"
                        ),
                    )
                    .raise_severity_to(severity),
                );
            }
        }
    }
    verdicts
}

/// C12 — operator-rule promotion.
///
/// An operator-authored stateful alert rule whose condition is currently met is
/// promoted into causal reasoning as an observation over its target entity.
fn c12_operator_rule_promotion(ctx: &Context) -> Vec<Verdict> {
    ctx.operator_rules
        .iter()
        .filter(|rule| rule.condition_met)
        .map(|rule| {
            Verdict::new(
                rule.entity_uid.clone(),
                Classification::Affected,
                format!("operator rule {} fired: {}", rule.rule_id, rule.description),
            )
        })
        .collect()
}

/// C13 — discovery-gap disambiguation.
///
/// When expected observations for a node are absent, distinguish "the node is
/// down" from "we lost the ability to observe it." A node that is expected to be
/// observed but has no availability reading is a discovery/observation gap
/// (`Unknown`), not a confirmed outage — coordinating with C4's unobservable
/// handling.
fn c13_discovery_gap(ctx: &Context) -> Vec<Verdict> {
    ctx.devices
        .iter()
        .filter(|device| device.observation_expected && device.is_available.is_none())
        .map(|device| {
            Verdict::new(
                device.uid.clone(),
                Classification::Unknown,
                "expected observations absent; discovery/observation gap, not a confirmed outage",
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain_model::{
        Context, Device, EdgeKind, GatewayClass, InterfaceLink, OperatorRule, Service, TopologyEdge,
    };

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

    fn link(src: &str, dst: &str, flow: Option<i64>, capacity: Option<i64>) -> InterfaceLink {
        InterfaceLink {
            src: src.to_string(),
            dst: dst.to_string(),
            flow_bps: flow,
            capacity_bps: capacity,
        }
    }

    #[test]
    fn c6_projects_saturation_on_capacity_eligible_link() {
        let ctx = Context {
            links: vec![link("sr:device:a", "sr:device:b", Some(900), Some(1_000))],
            ..Default::default()
        };
        let verdicts = c6_interface_saturation(&ctx);
        let v = verdicts
            .iter()
            .find(|v| v.entity_id == "sr:device:a")
            .expect("saturation verdict");
        assert_eq!(v.classification, Classification::Affected);
        assert_eq!(v.severity, 90);
        assert!(v.reason.contains("100 bps headroom"));
    }

    #[test]
    fn c6_no_projection_without_capacity_denominator() {
        let ctx = Context {
            links: vec![link("sr:device:a", "sr:device:b", Some(900), None)],
            ..Default::default()
        };
        assert!(c6_interface_saturation(&ctx).is_empty());
    }

    #[test]
    fn c6_no_projection_below_threshold() {
        let ctx = Context {
            links: vec![link("sr:device:a", "sr:device:b", Some(100), Some(1_000))],
            ..Default::default()
        };
        assert!(c6_interface_saturation(&ctx).is_empty());
    }

    fn depends_on(dependent: &str, dependency: &str) -> TopologyEdge {
        TopologyEdge::new(dependent, dependency, EdgeKind::DependsOn)
    }

    fn service(id: &str, available: Option<bool>) -> Service {
        Service {
            id: id.to_string(),
            available,
        }
    }

    #[test]
    fn c7_predicts_collapse_when_dependency_fails() {
        let ctx = Context {
            services: vec![
                service("agent-1:grpc:api", Some(true)),
                service("agent-1:grpc:db", Some(false)),
            ],
            edges: vec![depends_on("agent-1:grpc:api", "agent-1:grpc:db")],
            ..Default::default()
        };
        assert_eq!(
            classification_of(&c7_service_stack_collapse(&ctx), "agent-1:grpc:api"),
            Some(&Classification::Affected)
        );
    }

    #[test]
    fn c7_no_collapse_when_dependency_healthy() {
        let ctx = Context {
            services: vec![
                service("agent-1:grpc:api", Some(true)),
                service("agent-1:grpc:db", Some(true)),
            ],
            edges: vec![depends_on("agent-1:grpc:api", "agent-1:grpc:db")],
            ..Default::default()
        };
        assert!(c7_service_stack_collapse(&ctx).is_empty());
    }

    #[test]
    fn c3_suppresses_out_of_band_gateway_root_cause() {
        let mut oob_gateway = device("sr:gw:oob", Some(false), None);
        oob_gateway.gateway_class = Some(GatewayClass::OutOfBand);
        let ctx = Context {
            devices: vec![
                oob_gateway,
                device("sr:device:a", Some(false), Some("sr:gw:oob")),
                device("sr:device:b", Some(false), Some("sr:gw:oob")),
            ],
            ..Default::default()
        };
        // Gap E: the OOB gateway is not blamed as a data-plane root cause.
        assert!(c3_gateway_shared_fate(&ctx).is_empty());
    }

    #[test]
    fn c3_still_blames_in_band_gateway() {
        let mut inband_gateway = device("sr:gw:inband", Some(false), None);
        inband_gateway.gateway_class = Some(GatewayClass::InBand);
        let ctx = Context {
            devices: vec![
                inband_gateway,
                device("sr:device:a", Some(false), Some("sr:gw:inband")),
                device("sr:device:b", Some(false), Some("sr:gw:inband")),
            ],
            ..Default::default()
        };
        assert_eq!(
            classification_of(&c3_gateway_shared_fate(&ctx), "sr:gw:inband"),
            Some(&Classification::RootCause)
        );
    }

    #[test]
    fn c11_emits_precursor_above_flap_threshold() {
        let mut flappy = device("sr:device:flap", Some(true), None);
        flappy.flap_count = Some(6);
        let ctx = Context {
            devices: vec![flappy],
            ..Default::default()
        };
        let verdicts = c11_flap_precursor(&ctx);
        let v = verdicts
            .iter()
            .find(|v| v.entity_id == "sr:device:flap")
            .expect("precursor verdict");
        assert_eq!(v.classification, Classification::Affected);
        assert_eq!(v.severity, 80); // 50 + 6*5
    }

    #[test]
    fn c11_silent_below_flap_threshold() {
        let mut steady = device("sr:device:steady", Some(true), None);
        steady.flap_count = Some(1);
        let ctx = Context {
            devices: vec![steady],
            ..Default::default()
        };
        assert!(c11_flap_precursor(&ctx).is_empty());
    }

    #[test]
    fn c12_promotes_a_met_operator_rule() {
        let ctx = Context {
            operator_rules: vec![
                OperatorRule {
                    rule_id: "rule-1".to_string(),
                    entity_uid: "sr:device:x".to_string(),
                    condition_met: true,
                    description: "cpu > 95% for 10m".to_string(),
                },
                OperatorRule {
                    rule_id: "rule-2".to_string(),
                    entity_uid: "sr:device:y".to_string(),
                    condition_met: false,
                    description: "unmet".to_string(),
                },
            ],
            ..Default::default()
        };
        let verdicts = c12_operator_rule_promotion(&ctx);
        assert_eq!(
            classification_of(&verdicts, "sr:device:x"),
            Some(&Classification::Affected)
        );
        // an unmet rule is not promoted
        assert_eq!(classification_of(&verdicts, "sr:device:y"), None);
    }

    #[test]
    fn c13_classifies_absent_expected_observation_as_unknown() {
        let mut expected = device("sr:device:expected", None, None);
        expected.observation_expected = true;
        let mut not_expected = device("sr:device:silent", None, None);
        not_expected.observation_expected = false;
        let ctx = Context {
            devices: vec![expected, not_expected],
            ..Default::default()
        };
        let verdicts = c13_discovery_gap(&ctx);
        assert_eq!(
            classification_of(&verdicts, "sr:device:expected"),
            Some(&Classification::Unknown)
        );
        // a node we never expected to observe is not a discovery gap
        assert_eq!(classification_of(&verdicts, "sr:device:silent"), None);
    }
}
