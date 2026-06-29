//! V1 domain model — Rust types for the entities and relationships the engine
//! reasons over. These are projected into the DeepCausality `Context` by the
//! hydrator. Identity discipline (add-causal-engine): every entity is keyed by
//! the canonical `sr:`-prefixed id reused from `RuntimeGraph` — the engine never
//! invents a parallel ID space (`ocsf_devices.uid == AGE Device.id ==
//! ocsf_events.device.uid`).

use serde::{Deserialize, Serialize};

/// Canonical, `sr:`-prefixed entity identifier.
pub type EntityId = String;

/// Default maximum age for live operator-rule evidence. This bounds stale
/// causal findings when a producer never sends the matching clear signal.
pub const DEFAULT_OPERATOR_RULE_TTL_MS: i64 = 24 * 60 * 60 * 1_000;

/// A topology edge kind projected from the AGE graph.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum EdgeKind {
    /// Physical link (`CONNECTS_TO`, undirected) — the graph causaloids
    /// (C5/C5b/C9) reason over this view.
    ConnectsTo,
    /// Management relationship (`MANAGED_BY`): `src` is managed by `dst` (C4).
    ManagedBy,
    /// Virtualization containment (`CONTAINS`): `src` (host) contains `dst`
    /// (guest) (C1).
    Contains,
    /// Storage backing (`BACKED_BY`): `src` (guest virtual disk) is backed by
    /// `dst` (datastore) (C2).
    BackedBy,
    /// Service dependency (`DEPENDS_ON`): `src` depends on `dst` (service, host,
    /// or resource) (C7).
    DependsOn,
}

/// A directed topology edge between two canonical entity ids.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TopologyEdge {
    /// Source entity id.
    pub src: EntityId,
    /// Destination entity id.
    pub dst: EntityId,
    /// Edge kind.
    pub kind: EdgeKind,
}

impl TopologyEdge {
    /// Construct a topology edge.
    pub fn new(src: impl Into<EntityId>, dst: impl Into<EntityId>, kind: EdgeKind) -> Self {
        Self {
            src: src.into(),
            dst: dst.into(),
            kind,
        }
    }
}

/// Observability gateway classification (Gap E). A management/out-of-band path
/// is not in-band data-plane reachability, so causaloid C3 must not blame an
/// OOB gateway failure as a data-plane root cause.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum GatewayClass {
    /// In-band data-plane path (default; a failure can be a data-plane root cause).
    InBand,
    /// Out-of-band path (e.g. console/lights-out) — never a data-plane root cause.
    OutOfBand,
    /// Dedicated management network — never a data-plane root cause.
    Management,
}

/// A point-in-time interface/link saturation observation for causaloid C6.
///
/// `flow_bps` is the observed throughput and `capacity_bps` the link's
/// engineered capacity (min-of-both-ends per the Gap B eligibility contract).
/// C6 only projects saturation when a capacity denominator is present.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InterfaceLink {
    /// Source endpoint of the link.
    pub src: EntityId,
    /// Destination endpoint of the link.
    pub dst: EntityId,
    /// Observed throughput in bits/sec (`None` when not yet observed).
    #[serde(default)]
    pub flow_bps: Option<i64>,
    /// Engineered capacity in bits/sec (`None` => capacity-ineligible, C6 skips).
    #[serde(default)]
    pub capacity_bps: Option<i64>,
}

/// An attributed flow source (Gap A / capability `service-flow-bridge`): a
/// `attributed_flow` row binding a flow to a canonical source/destination. Drives
/// causaloid C10's risk-weighted blast radius.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttributedFlow {
    /// Canonical source entity (the traffic origin).
    pub src_uid: EntityId,
    /// Canonical destination entity.
    pub dst_uid: EntityId,
    /// Source per-device risk (MAX-wins `DeviceRiskReducer`); weights C10 severity.
    #[serde(default)]
    pub src_risk_score: Option<i64>,
}

/// A BGP route observation for causaloid C8. A withdrawn route names the
/// downstream destinations that lose reachability.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BgpRoute {
    /// The advertised/withdrawn prefix (e.g. `10.0.0.0/24`).
    pub prefix: String,
    /// True when the route has been withdrawn.
    pub withdrawn: bool,
    /// Canonical id of the speaker that originated/withdrew the route.
    pub origin_uid: EntityId,
    /// Canonical ids of downstream destinations that lose reachability on withdrawal.
    #[serde(default)]
    pub downstream_uids: Vec<EntityId>,
}

/// An operator-authored stateful alert rule (from `stateful_alert_rules`) whose
/// condition is currently met, promoted into the rule evaluation by rule C12.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OperatorRule {
    /// Stable rule identifier.
    pub rule_id: String,
    /// Canonical entity the rule's condition currently applies to.
    pub entity_uid: EntityId,
    /// Whether the rule's condition is currently met.
    pub condition_met: bool,
    /// Human-readable rule description (drives the verdict explanation).
    pub description: String,
    /// Last time this live evidence was updated, in Unix milliseconds.
    #[serde(default)]
    pub last_updated_unix_ms: i64,
}

/// Drop operator-rule evidence older than the configured TTL. A non-positive
/// TTL disables pruning.
pub fn prune_stale_operator_rules(context: &mut Context, now_unix_ms: i64, ttl_ms: i64) -> usize {
    if ttl_ms <= 0 {
        return 0;
    }

    let cutoff = now_unix_ms.saturating_sub(ttl_ms);
    let before = context.operator_rules.len();

    context
        .operator_rules
        .retain(|rule| rule.last_updated_unix_ms >= cutoff);

    before.saturating_sub(context.operator_rules.len())
}

/// The hydrated world-state the reasoner evaluates each tick.
///
/// Populated from `EmbeddedSrql` (current state + on-demand continuous-aggregate
/// queries + AGE topology via `graph_cypher`) merged with JetStream and
/// `signals.state.<table>` deltas.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Context {
    /// Devices keyed by canonical `uid`.
    pub devices: Vec<Device>,
    /// Services (composite identity per Decision 2).
    pub services: Vec<Service>,
    /// Topology edges (CONNECTS_TO / MANAGED_BY / CONTAINS / BACKED_BY /
    /// DEPENDS_ON) projected from the AGE graph.
    #[serde(default)]
    pub edges: Vec<TopologyEdge>,
    /// Interface/link saturation observations (capacity-eligible edges, C6).
    #[serde(default)]
    pub links: Vec<InterfaceLink>,
    /// Attributed-flow sources for blast-radius reasoning (C10).
    #[serde(default)]
    pub flows: Vec<AttributedFlow>,
    /// BGP route observations for reachability-degradation reasoning (C8).
    #[serde(default)]
    pub bgp_routes: Vec<BgpRoute>,
    /// Operator-authored rules whose conditions are met (C12).
    #[serde(default)]
    pub operator_rules: Vec<OperatorRule>,
}

/// A device (from `ocsf_devices` + AGE `Device` vertex).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Device {
    /// Canonical `sr:`-prefixed uid.
    pub uid: EntityId,
    /// Binary availability (`None` when unknown / not yet observed).
    pub is_available: Option<bool>,
    /// Whether the device is managed.
    pub is_managed: Option<bool>,
    /// MAX-wins device risk from `DeviceRiskReducer` (composed into C5/C7/C10).
    pub risk_score: Option<i64>,
    /// Observability gateway this device reports through (shared-fate key for C3).
    #[serde(default)]
    pub gateway_id: Option<EntityId>,
    /// Gateway class (Gap E) — set on gateway devices so C3 can suppress OOB blame.
    #[serde(default)]
    pub gateway_class: Option<GatewayClass>,
    /// Recent state-flap count (rapid repeated transitions) — drives C11.
    #[serde(default)]
    pub flap_count: Option<i64>,
    /// True when this node is expected to be observed (so an absent observation
    /// is a discovery gap, not a confirmed outage) — drives C13.
    #[serde(default)]
    pub observation_expected: bool,
    /// Bounded worst package/vulnerability severity scalar (0..=10) projected
    /// onto the AGE `Device` vertex (`pkg_worst_severity`); composed into the
    /// predicted severity of C5/C7/C10 (task 1.5) without altering the structural
    /// conclusion.
    #[serde(default)]
    pub pkg_severity: Option<i64>,
}

/// A service (from `service_status` / `service_state`).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Service {
    /// Composite service identity (`agent_id:service_type:service_name`).
    pub id: EntityId,
    /// Availability (`None` when unknown).
    pub available: Option<bool>,
}
