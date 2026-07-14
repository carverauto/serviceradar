//! The propagating verdict `V` and its lawful bounded-lattice `Verdict` implementation.

use crate::confidence::{ConfidenceSummary, conf_glb, conf_lub};
use crate::entity::{Domain, EntityKey};
use deep_causality_algebra::Verdict;
use uuid::Uuid;

/// Unix time in nanoseconds.
pub type Timestamp = i64;

/// ATT&CK-tactic-ordered kill-chain progression. `Ord` so `join` can take `stage.max` (escalate to
/// the furthest-progressed stage).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
pub enum Stage {
    #[default]
    Recon = 1,
    InitialAccess,
    Execution,
    Persistence,
    PrivEsc,
    CredAccess,
    Discovery,
    Lateral,
    Collection,
    C2,
    Exfil,
    Impact,
}

/// Asset-criticality-weighted severity (OCSF-aligned 1..=5). `Ord` for `severity.max`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
pub enum Severity {
    #[default]
    Informational = 1,
    Low,
    Medium,
    High,
    Critical,
}

/// Which genuinely-independent evidence cluster a signal belongs to. Correlated same-session signals
/// share a cluster and are collapsed to one unit before cross-cluster fusion (§4.3).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EvidenceCluster {
    Session,
    HostRuntime,
    Recon,
    Auth,
}

/// One piece of provenance backing a verdict — the causal narrative, and the SOC-legible trail.
#[derive(Clone, Debug, PartialEq)]
pub struct EvidenceRef {
    pub domain: Domain,
    pub ocsf_event_id: Uuid,
    /// ATT&CK technique id (e.g. `"T1071"`); populated by the technique-tagging milestone.
    pub attck: Option<String>,
    pub signal_conf: ConfidenceSummary,
    pub observed_at: Timestamp,
    pub cluster: EvidenceCluster,
}

/// The propagating verdict.
///
/// A lawful bounded lattice: `Benign` is the bottom (join identity), `Saturated` is the abstract top
/// (meet identity), and `Incident` verdicts form a product lattice over `(stage, confidence, severity)`
/// with evidence unioned. `join` combines confidence by max-on-mean, so it performs NO sampling.
/// Reasoning only ever produces `Benign`/`Incident`; `Saturated` exists to satisfy the lattice `top`.
#[derive(Clone, Debug, Default, PartialEq)]
pub enum SecVerdict {
    /// Lattice bottom / join identity.
    #[default]
    Benign,
    /// A fused verdict about ONE incident hypothesis (all `Incident`s in a per-incident graph share
    /// an `entity`).
    Incident {
        entity: EntityKey,
        stage: Stage,
        confidence: ConfidenceSummary,
        severity: Severity,
        evidence: Vec<EvidenceRef>,
    },
    /// Lattice top / meet identity.
    Saturated,
}

/// Canonical evidence order (by `(ocsf_event_id, domain)`) so set-equal evidence compares equal under
/// structural `PartialEq` regardless of the order it was unioned — required for `join`/`meet` to be
/// associative and commutative.
fn canonicalize(mut ev: Vec<EvidenceRef>) -> Vec<EvidenceRef> {
    ev.sort_by_key(|e| (e.ocsf_event_id, e.domain));
    ev
}

/// Union `b` into `a`, de-duplicating by `(ocsf_event_id, domain)` and canonicalizing order.
/// Associative, commutative, and — with de-duplication — idempotent, which the lattice laws require.
fn dedup_union(mut a: Vec<EvidenceRef>, b: Vec<EvidenceRef>) -> Vec<EvidenceRef> {
    for e in b {
        if !a
            .iter()
            .any(|x| x.ocsf_event_id == e.ocsf_event_id && x.domain == e.domain)
        {
            a.push(e);
        }
    }
    canonicalize(a)
}

/// The evidence common to both (keyed by `(ocsf_event_id, domain)`), canonicalized.
fn intersect(a: &[EvidenceRef], b: &[EvidenceRef]) -> Vec<EvidenceRef> {
    canonicalize(
        a.iter()
            .filter(|x| {
                b.iter()
                    .any(|y| y.ocsf_event_id == x.ocsf_event_id && y.domain == x.domain)
            })
            .cloned()
            .collect(),
    )
}

impl Verdict for SecVerdict {
    fn bottom() -> Self {
        SecVerdict::Benign
    }

    fn top() -> Self {
        SecVerdict::Saturated
    }

    /// Least upper bound. `Benign` is the identity; `Saturated` absorbs; two `Incident`s combine
    /// field-wise (`stage.max`, confidence max-on-mean, `severity.max`, evidence union). The `entity`
    /// coordinate uses `min` so the operation stays a lawful (associative/commutative) semilattice
    /// even for the degenerate cross-entity case; within a per-incident graph the entity is fixed.
    fn join(self, other: Self) -> Self {
        use SecVerdict::*;
        match (self, other) {
            (Saturated, _) | (_, Saturated) => Saturated,
            (Benign, x) | (x, Benign) => x,
            (
                Incident {
                    entity: ea,
                    stage: sa,
                    confidence: ca,
                    severity: va,
                    evidence: xa,
                },
                Incident {
                    entity: eb,
                    stage: sb,
                    confidence: cb,
                    severity: vb,
                    evidence: xb,
                },
            ) => {
                debug_assert_eq!(ea, eb, "per-incident graph: join is same-entity by design");
                Incident {
                    entity: core::cmp::min(ea, eb),
                    stage: sa.max(sb),
                    confidence: conf_lub(ca, cb),
                    severity: va.max(vb),
                    evidence: dedup_union(xa, xb),
                }
            }
        }
    }

    /// Greatest lower bound (dual of `join`).
    fn meet(self, other: Self) -> Self {
        use SecVerdict::*;
        match (self, other) {
            (Benign, _) | (_, Benign) => Benign,
            (Saturated, x) | (x, Saturated) => x,
            (
                Incident {
                    entity: ea,
                    stage: sa,
                    confidence: ca,
                    severity: va,
                    evidence: xa,
                },
                Incident {
                    entity: eb,
                    stage: sb,
                    confidence: cb,
                    severity: vb,
                    evidence: xb,
                },
            ) => Incident {
                entity: core::cmp::max(ea, eb),
                stage: sa.min(sb),
                confidence: conf_glb(ca, cb),
                severity: va.min(vb),
                evidence: intersect(&xa, &xb),
            },
        }
    }

    /// MV-algebra complement on the confidence mean (`1 − mean`), swapping the lattice bounds. An
    /// involution (`complement(complement(x)) == x`); not used in reasoning, present to satisfy the
    /// `Verdict` bound.
    fn complement(self) -> Self {
        use SecVerdict::*;
        match self {
            Benign => Saturated,
            Saturated => Benign,
            Incident {
                entity,
                stage,
                confidence,
                severity,
                evidence,
            } => Incident {
                entity,
                stage,
                severity,
                evidence,
                confidence: ConfidenceSummary::new(1.0 - confidence.mean, confidence.variance),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(id: u128, domain: Domain) -> EvidenceRef {
        EvidenceRef {
            domain,
            ocsf_event_id: Uuid::from_u128(id),
            attck: None,
            signal_conf: ConfidenceSummary::new(0.7, 0.1),
            observed_at: 0,
            cluster: EvidenceCluster::Session,
        }
    }

    fn incident(
        mean: f64,
        stage: Stage,
        severity: Severity,
        evidence: Vec<EvidenceRef>,
    ) -> SecVerdict {
        SecVerdict::Incident {
            entity: EntityKey::new("sr:device:host-b"),
            stage,
            confidence: ConfidenceSummary::new(mean, 0.1),
            severity,
            evidence,
        }
    }

    #[test]
    fn benign_is_join_identity() {
        let x = incident(0.8, Stage::C2, Severity::High, vec![ev(1, Domain::Dns)]);
        assert_eq!(x.clone().join(SecVerdict::Benign), x);
        assert_eq!(SecVerdict::Benign.join(x.clone()), x);
        assert_eq!(SecVerdict::bottom(), SecVerdict::Benign);
    }

    #[test]
    fn saturated_absorbs_join() {
        let x = incident(0.8, Stage::C2, Severity::High, vec![]);
        assert_eq!(x.join(SecVerdict::Saturated), SecVerdict::Saturated);
    }

    #[test]
    fn join_escalates_without_double_counting() {
        let a = incident(
            0.6,
            Stage::Execution,
            Severity::Medium,
            vec![ev(1, Domain::Dns)],
        );
        let b = incident(
            0.9,
            Stage::C2,
            Severity::High,
            vec![ev(1, Domain::Dns), ev(2, Domain::Flow)],
        );
        match a.join(b) {
            SecVerdict::Incident {
                stage,
                confidence,
                severity,
                evidence,
                ..
            } => {
                assert_eq!(stage, Stage::C2); // furthest
                assert_eq!(severity, Severity::High); // worst
                assert!((confidence.mean - 0.9).abs() < 1e-9); // max-on-mean
                assert_eq!(evidence.len(), 2); // shared evidence counted once
            }
            other => panic!("expected Incident, got {other:?}"),
        }
    }

    #[test]
    fn join_is_idempotent() {
        let x = incident(
            0.7,
            Stage::Lateral,
            Severity::High,
            vec![ev(1, Domain::Auth)],
        );
        assert_eq!(x.clone().join(x.clone()), x);
    }

    #[test]
    fn join_is_commutative_and_associative() {
        let a = incident(0.2, Stage::Recon, Severity::Low, vec![ev(1, Domain::Scan)]);
        let b = incident(0.9, Stage::C2, Severity::High, vec![ev(2, Domain::Flow)]);
        let d = incident(
            0.5,
            Stage::Execution,
            Severity::Medium,
            vec![ev(3, Domain::Host)],
        );
        assert_eq!(a.clone().join(b.clone()), b.clone().join(a.clone()));
        assert_eq!(
            a.clone().join(b.clone()).join(d.clone()),
            a.clone().join(b.clone().join(d.clone()))
        );
    }

    #[test]
    fn absorption_holds() {
        let a = incident(
            0.4,
            Stage::Execution,
            Severity::Medium,
            vec![ev(1, Domain::Dns)],
        );
        let b = incident(0.8, Stage::C2, Severity::High, vec![ev(2, Domain::Flow)]);
        assert_eq!(a.clone().join(a.clone().meet(b.clone())), a);
        assert_eq!(a.clone().meet(a.clone().join(b.clone())), a);
    }

    #[test]
    fn complement_is_involution() {
        let x = incident(0.75, Stage::C2, Severity::High, vec![ev(1, Domain::Dns)]);
        assert_eq!(x.clone().complement().complement(), x);
        assert_eq!(SecVerdict::Benign.complement(), SecVerdict::Saturated);
        assert_eq!(SecVerdict::Saturated.complement(), SecVerdict::Benign);
    }
}
