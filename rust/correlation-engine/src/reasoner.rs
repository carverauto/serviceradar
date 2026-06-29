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
use crate::graph::TopologyGraph;

/// A gateway is flagged as a shared-fate root cause when at least this many of
/// the devices that observe through it are simultaneously unavailable (C3).
const GATEWAY_SHARED_FATE_THRESHOLD: usize = 2;

/// A link is flagged by C6 as projected-saturated at or above this percent
/// utilization (observed `flow_bps` / engineered `capacity_bps`).
const SATURATION_UTILIZATION_PCT: i64 = 80;

/// A node with at least this many recent state transitions is flagged by C11 as
/// an instability precursor.
const FLAP_PRECURSOR_THRESHOLD: i64 = 3;

/// A node whose normalized betweenness centrality is at or above this value is
/// flagged by C9 as a shared-hop bottleneck.
const SHARED_HOP_BETWEENNESS_THRESHOLD: f64 = 0.3;

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

/// Per-device composed risk on a 0..=100 scale (task 1.5): the larger of the
/// MAX-wins `risk_score` and the bounded `pkg_severity` (CVSS 0..=10, scaled
/// ×10). Used to raise — never alter — the predicted severity of C5/C7/C10 for
/// the affected node. Devices with no risk are omitted.
fn device_risk(ctx: &Context) -> HashMap<&str, u8> {
    let mut map = HashMap::new();
    for device in &ctx.devices {
        let score = device.risk_score.unwrap_or(0).clamp(0, 100);
        let pkg = device.pkg_severity.unwrap_or(0).clamp(0, 10) * 10;
        let risk = score.max(pkg);
        if risk > 0 {
            map.insert(device.uid.as_str(), risk as u8);
        }
    }
    map
}

/// The DeepCausality reasoner.
#[derive(Default)]
pub struct Reasoner {
    // V1 builds the topology CausaloidGraph per tick. A later optimization can
    // cache/unfreeze it only on topology changes if that shows up in profiles.
}

impl Reasoner {
    /// Construct a reasoner.
    pub fn new() -> Self {
        Self::default()
    }

    /// Run one reasoning tick over the hydrated context, evaluating every
    /// implemented causaloid (C1–C13) and collecting verdicts.
    pub fn evaluate(&self, ctx: &Context) -> Result<Vec<Verdict>> {
        let mut verdicts = Vec::new();
        // Per-device risk composed into C5/C7/C10 severity (task 1.5).
        let risk = device_risk(ctx);

        // Non-graph causaloids over Context state / metrics / risk.
        verdicts.extend(c1_containment_cascade(ctx));
        verdicts.extend(c2_datastore_cascade(ctx));
        verdicts.extend(c3_gateway_shared_fate(ctx));
        verdicts.extend(c4_management_unobservable(ctx));
        verdicts.extend(c6_interface_saturation(ctx));
        verdicts.extend(c7_service_stack_collapse(ctx, &risk));
        verdicts.extend(c11_flap_precursor(ctx));
        verdicts.extend(c12_operator_rule_promotion(ctx));
        verdicts.extend(c13_discovery_gap(ctx));
        verdicts.extend(c8_bgp_withdrawal(ctx));

        // Graph causaloids over the frozen CONNECTS_TO topology (C5/C5b/C9/C10).
        if let Some(graph) = TopologyGraph::from_connects_to(ctx) {
            verdicts.extend(c5_single_point_of_failure(&graph, &risk));
            verdicts.extend(c5b_bridge_redundancy_gap(&graph));
            verdicts.extend(c9_shared_hop_bottleneck(&graph));
            verdicts.extend(c10_blast_radius(ctx, &graph, &risk));
        }
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
        if device.is_available == Some(false)
            && let Some(gateway) = device.gateway_id.as_deref()
        {
            unavailable_by_gateway
                .entry(gateway)
                .or_default()
                .push(device);
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
fn c7_service_stack_collapse(ctx: &Context, risk: &HashMap<&str, u8>) -> Vec<Verdict> {
    let availability = entity_availability_map(ctx);
    let mut verdicts = Vec::new();
    for edge in &ctx.edges {
        if edge.kind == EdgeKind::DependsOn
            && availability.get(edge.dst.as_str()) == Some(&Some(false))
        {
            let mut verdict = Verdict::new(
                edge.src.clone(),
                Classification::Affected,
                format!(
                    "dependency {} is unavailable; dependent stack predicted to collapse",
                    edge.dst
                ),
            );
            // Risk composition (1.5): a higher-risk dependent stack is more severe.
            if let Some(&r) = risk.get(edge.src.as_str()) {
                verdict = verdict.raise_severity_to(r);
            }
            verdicts.push(verdict);
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
        if let Some(flaps) = device.flap_count
            && flaps >= FLAP_PRECURSOR_THRESHOLD
        {
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
    verdicts
}

/// C12 — operator-rule promotion.
///
/// An operator-authored stateful alert rule whose condition is currently met is
/// promoted into the rule evaluation as an observation over its target entity.
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

/// C5 — standing single-point-of-failure warning.
///
/// An articulation point in the physical topology is a node whose loss would
/// partition reachability, so it is flagged as a standing SPOF even with no
/// active fault. (`StructuralGraphAlgorithms::articulation_points`.)
fn c5_single_point_of_failure(graph: &TopologyGraph, risk: &HashMap<&str, u8>) -> Vec<Verdict> {
    graph
        .articulation_points()
        .into_iter()
        .map(|id| {
            let verdict = Verdict::new(
                id.clone(),
                Classification::Affected,
                format!(
                    "articulation point: loss of {id} would partition reachability (standing SPOF)"
                ),
            );
            // Risk composition (1.5): a high-risk SPOF node is more severe; the
            // structural articulation-point conclusion itself is unchanged.
            match risk.get(id.as_str()) {
                Some(&r) => verdict.raise_severity_to(r),
                None => verdict,
            }
        })
        .collect()
}

/// C5b — standing redundancy-gap warning on bridge edges.
///
/// A bridge edge has no redundant path; losing it partitions reachability. Both
/// endpoints are flagged so the missing redundancy is visible on either side.
/// (`StructuralGraphAlgorithms::bridges`.)
fn c5b_bridge_redundancy_gap(graph: &TopologyGraph) -> Vec<Verdict> {
    let mut verdicts = Vec::new();
    for (a, b) in graph.bridges() {
        verdicts.push(Verdict::new(
            a.clone(),
            Classification::Affected,
            format!("bridge link to {b}: no redundant path; its loss partitions reachability"),
        ));
        verdicts.push(Verdict::new(
            b.clone(),
            Classification::Affected,
            format!("bridge link to {a}: no redundant path; its loss partitions reachability"),
        ));
    }
    verdicts
}

/// C8 — BGP withdrawal reachability degradation.
///
/// A withdrawn route degrades reachability for the downstream destinations it
/// served; emit an affected verdict for each.
fn c8_bgp_withdrawal(ctx: &Context) -> Vec<Verdict> {
    let mut verdicts = Vec::new();
    for route in &ctx.bgp_routes {
        if !route.withdrawn {
            continue;
        }
        for downstream in &route.downstream_uids {
            verdicts.push(Verdict::new(
                downstream.clone(),
                Classification::Affected,
                format!(
                    "BGP prefix {} withdrawn by {}; downstream reachability degraded",
                    route.prefix, route.origin_uid
                ),
            ));
        }
    }
    verdicts
}

/// C9 — shared-hop bottleneck detection.
///
/// A node with high betweenness centrality is a shared hop many paths traverse;
/// a fault there concentrates blast radius. Flag nodes at or above the
/// betweenness threshold. (`CentralityGraphAlgorithms::betweenness_centrality`.)
fn c9_shared_hop_bottleneck(graph: &TopologyGraph) -> Vec<Verdict> {
    graph
        .betweenness()
        .into_iter()
        .filter(|(_, score)| *score >= SHARED_HOP_BETWEENNESS_THRESHOLD)
        .map(|(id, score)| {
            let severity = (50.0 + score * 50.0).clamp(0.0, 100.0) as u8;
            Verdict::new(
                id.clone(),
                Classification::Affected,
                format!(
                    "shared-hop bottleneck (betweenness {score:.2}); concentrates blast radius"
                ),
            )
            .raise_severity_to(severity)
        })
        .collect()
}

/// C10 — traffic-source blast radius.
///
/// For each attributed-flow source, the blast radius is everything reachable
/// from it in the physical topology; the predicted severity is weighted by the
/// source's per-device risk (`PathfindingGraphAlgorithms::is_reachable`).
fn c10_blast_radius(
    ctx: &Context,
    graph: &TopologyGraph,
    risk: &HashMap<&str, u8>,
) -> Vec<Verdict> {
    let mut verdicts = Vec::new();
    for flow in &ctx.flows {
        let reachable = graph.reachable_from(&flow.src_uid);
        if reachable.is_empty() {
            continue;
        }
        let flow_risk = flow.src_risk_score.unwrap_or(0).clamp(0, 100);
        // Risk dominates: a low-risk source yields a lower-severity blast radius
        // than an identical high-risk one (spec C10 scenario).
        let severity = (40 + flow_risk / 2).clamp(0, 100) as u8;
        let mut verdict = Verdict::new(
            flow.src_uid.clone(),
            Classification::Affected,
            format!(
                "attributed-flow source reaches {} destination(s); risk-weighted blast radius (source risk {})",
                reachable.len(),
                flow_risk
            ),
        )
        .raise_severity_to(severity);
        // Risk composition (1.5): fold in the source device's per-device risk
        // (MAX-wins, so it never double-counts the flow weighting).
        if let Some(&r) = risk.get(flow.src_uid.as_str()) {
            verdict = verdict.raise_severity_to(r);
        }
        verdicts.push(verdict);
    }
    verdicts
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain_model::{
        AttributedFlow, BgpRoute, Context, Device, EdgeKind, GatewayClass, InterfaceLink,
        OperatorRule, Service, TopologyEdge,
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

    fn no_risk() -> HashMap<&'static str, u8> {
        HashMap::new()
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
        assert!(
            verdicts
                .iter()
                .any(|v| v.entity_id == "sr:gw:1" && v.classification == Classification::RootCause)
        );
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
            classification_of(
                &c7_service_stack_collapse(&ctx, &no_risk()),
                "agent-1:grpc:api"
            ),
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
        assert!(c7_service_stack_collapse(&ctx, &no_risk()).is_empty());
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
                    last_updated_unix_ms: 1_000,
                },
                OperatorRule {
                    rule_id: "rule-2".to_string(),
                    entity_uid: "sr:device:y".to_string(),
                    condition_met: false,
                    description: "unmet".to_string(),
                    last_updated_unix_ms: 1_000,
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

    fn connects(a: &str, b: &str) -> TopologyEdge {
        TopologyEdge::new(a, b, EdgeKind::ConnectsTo)
    }

    /// a - b - c line: b is the articulation point / both edges bridges / b is
    /// the highest-betweenness shared hop.
    fn line_topology() -> Context {
        Context {
            edges: vec![connects("sr:d:a", "sr:d:b"), connects("sr:d:b", "sr:d:c")],
            ..Default::default()
        }
    }

    #[test]
    fn c5_flags_articulation_point() {
        let graph = TopologyGraph::from_connects_to(&line_topology()).expect("graph");
        let verdicts = c5_single_point_of_failure(&graph, &no_risk());
        assert_eq!(
            classification_of(&verdicts, "sr:d:b"),
            Some(&Classification::Affected)
        );
        assert_eq!(classification_of(&verdicts, "sr:d:a"), None);
    }

    #[test]
    fn c5b_flags_both_endpoints_of_a_bridge() {
        let graph = TopologyGraph::from_connects_to(&line_topology()).expect("graph");
        let verdicts = c5b_bridge_redundancy_gap(&graph);
        // every node sits on a bridge in a line, so all are flagged
        for node in ["sr:d:a", "sr:d:b", "sr:d:c"] {
            assert_eq!(
                classification_of(&verdicts, node),
                Some(&Classification::Affected),
                "{node} should be flagged"
            );
        }
    }

    #[test]
    fn c9_flags_high_betweenness_hop() {
        let graph = TopologyGraph::from_connects_to(&line_topology()).expect("graph");
        let verdicts = c9_shared_hop_bottleneck(&graph);
        // b carries all paths between a and c => high betweenness
        assert_eq!(
            classification_of(&verdicts, "sr:d:b"),
            Some(&Classification::Affected)
        );
        // leaves carry no through-paths
        assert_eq!(classification_of(&verdicts, "sr:d:a"), None);
    }

    #[test]
    fn c10_blast_radius_severity_tracks_source_risk() {
        let mut ctx = line_topology();
        ctx.flows = vec![AttributedFlow {
            src_uid: "sr:d:a".to_string(),
            dst_uid: "sr:d:c".to_string(),
            src_risk_score: Some(90),
        }];
        let graph = TopologyGraph::from_connects_to(&ctx).expect("graph");
        let high = c10_blast_radius(&ctx, &graph, &no_risk());
        let high_sev = high
            .iter()
            .find(|v| v.entity_id == "sr:d:a")
            .map(|v| v.severity)
            .expect("blast verdict");

        ctx.flows[0].src_risk_score = Some(0);
        let low = c10_blast_radius(&ctx, &graph, &no_risk());
        let low_sev = low
            .iter()
            .find(|v| v.entity_id == "sr:d:a")
            .unwrap()
            .severity;

        assert!(
            high_sev > low_sev,
            "high risk {high_sev} > low risk {low_sev}"
        );
    }

    #[test]
    fn c8_degrades_downstream_on_withdrawal() {
        let ctx = Context {
            bgp_routes: vec![BgpRoute {
                prefix: "10.0.0.0/24".to_string(),
                withdrawn: true,
                origin_uid: "sr:d:edge".to_string(),
                downstream_uids: vec!["sr:d:x".to_string(), "sr:d:y".to_string()],
            }],
            ..Default::default()
        };
        let verdicts = c8_bgp_withdrawal(&ctx);
        assert_eq!(
            classification_of(&verdicts, "sr:d:x"),
            Some(&Classification::Affected)
        );
        assert_eq!(
            classification_of(&verdicts, "sr:d:y"),
            Some(&Classification::Affected)
        );
    }

    #[test]
    fn c8_silent_when_route_present() {
        let ctx = Context {
            bgp_routes: vec![BgpRoute {
                prefix: "10.0.0.0/24".to_string(),
                withdrawn: false,
                origin_uid: "sr:d:edge".to_string(),
                downstream_uids: vec!["sr:d:x".to_string()],
            }],
            ..Default::default()
        };
        assert!(c8_bgp_withdrawal(&ctx).is_empty());
    }

    #[test]
    fn c5_severity_raised_by_device_risk_without_changing_classification() {
        let mut ctx = line_topology();
        // make the articulation point (sr:d:b) a high-risk device
        let mut hub = device("sr:d:b", Some(true), None);
        hub.risk_score = Some(95);
        ctx.devices = vec![hub];

        let risk = device_risk(&ctx);
        let graph = TopologyGraph::from_connects_to(&ctx).expect("graph");
        let verdicts = c5_single_point_of_failure(&graph, &risk);
        let v = verdicts
            .iter()
            .find(|v| v.entity_id == "sr:d:b")
            .expect("spof verdict");
        // structural conclusion unchanged ...
        assert_eq!(v.classification, Classification::Affected);
        // ... but severity raised from the Affected base (50) to the risk (95).
        assert_eq!(v.severity, 95);
    }

    #[test]
    fn device_risk_takes_max_of_risk_score_and_scaled_pkg_severity() {
        let mut d = device("sr:d:b", Some(true), None);
        d.risk_score = Some(20);
        d.pkg_severity = Some(9); // 9 * 10 = 90 dominates risk_score 20
        let ctx = Context {
            devices: vec![d],
            ..Default::default()
        };
        assert_eq!(device_risk(&ctx).get("sr:d:b"), Some(&90));
    }
}
