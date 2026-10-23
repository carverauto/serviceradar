# Closure spike choices audit

This ledger covers the Decision 13 source investigation and executable models.
Decisions 11-13 are coordinator-approved givens. It does not approve the separate,
unpublished collector or choose a kernel closure mechanism.

## Sound choices, medium confidence

### Check small conditional models and preserve their counterexamples

- **When:** closure spike, 2026-10-23.
- **Choice:** use the existing TLC harness to explore small synthetic histories.
  For example, one outer operation remains pending while an inner operation
  overwrites its ticket. The unsafe configuration must expose acceptance without
  publishing the outer record. One startup frame, two operations, two sessions
  and one delayed failure are enough to exhibit those failures, but a pass does
  not cover arbitrary concurrency, capacity exhaustion or repeated failure.
- **Gap:** the spike required negative controls without selecting an implementable
  source barrier. Its abstract bootstrap/barrier actions can inspect outstanding
  work and hidden loss; production has not been shown to possess that knowledge.
  Two abstract deadline ticks demonstrate refusal on expiry, not real elapsed
  time, scheduler fairness or a useful proportion of accepted captures.
- **Reach:** later implementations must establish the abstract assumptions at their
  real source boundary. A generated successful receipt is never kernel evidence.
- **Verdict:** sound for bounded falsification; insufficient for runtime acceptance.
  Confidence is medium because the bounds expose the known failures but may omit
  interactions that a concrete mechanism introduces.

### Keep timing and publication obligations separate, without claiming composition

- **When:** model review, 2026-10-23.
- **Choice:** one model hides physical completion C between entry E and callback X;
  another models pending operations, publication and terminal acceptance. When
  E=1 and X=2, C=1 and C=2 belong to different intervals with identical observed
  evidence. Rejecting that bracket proves a local classification property. It
  does not prove how later socket state or fifteen-minute history recovers.
- **Gap:** one scalar C omits multiple effects within a call, failed operations,
  batches and timestamp uncertainty. The second model's completed queue is
  downstream publication work, not an active BPF callback. Retiring its pending
  ticket early demonstrates a bookkeeping hazard, whose exact production mapping
  depends on the eventual map and callback lifetimes.
- **Reach:** prefix closure alone can accept a callback observed after `Stop`;
  timing evidence must be composed with it before implementation proof is claimed.
- **Verdict:** sound as two explicitly separate counterexample owners. Confidence
  is medium; their composition and dependency propagation remain unproven.

### Abstract terminal delivery to a session token

- **When:** model review, 2026-10-23.
- **Choice:** a matching delivered token permits an audit; an absent, old or
  contradictory one cannot certify the session. For example, restarting from
  token 1 to token 2 leaves token 1's receipt unable to authorize token 2.
- **Gap:** the model does not enumerate the receipt's individual scalar members,
  partial sets, endpoint/sequence agreement or identical replay. Contradiction
  revokes the current `accepted` verdict; it does not undo actions taken by a
  consumer that trusted an earlier verdict or define evidence-retention duration.
- **Reach:** real producer/audit boundary tests must enforce the full Decision 13
  receipt contract. The token model is not warehouse-delivery verification.
- **Verdict:** sound for session/receipt counterexamples. Confidence is medium
  because transport and final consumer behavior remain outside its proof.

## Sound choice, high confidence

### Publish the negative spike evidence separately from the collector

- **When:** source search closeout, 2026-10-23.
- **Choice:** record the failed candidates, approved contract and model evidence
  in this PR while retaining the larger experimental collector unpublished.
  If a reviewer sees all model checks pass, the findings and open tasks still
  state that no deployable mechanism was established.
- **Gap:** the approved spike did not dictate how to publish an unsuccessful
  feasibility result. Expanding the loader or narrowing the whole-host population
  would require a new coordinator decision and was not attempted.
- **Reach:** future work inherits the rejected candidates and proof obligations
  without inheriting an unreviewed runtime implementation or false measurement gate.
- **Verdict:** sound, high confidence. It preserves useful evidence within the
  authorized scope; no architecture, rollout or gate relaxation is implied.
