## Context
ServiceRadar spans multiple languages and deployment planes. The highest-risk code is not concentrated in one service: browser authentication lives in Phoenix, policy and onboarding state live in Ash resources, gateway trust decisions live in Elixir gRPC services, plugin execution and self-update logic live in the Go agent, onboarding/bootstrap logic spans Go and Rust, and external exposure is heavily shaped by Helm/Kubernetes and local TLS/bootstrap assets.

The repository already contains several targeted hardening proposals, but there is no single approved baseline that says which directories must be reviewed together, how findings should be recorded, or how review output becomes tracked remediation work.

## Goals / Non-Goals
- Goals:
  - Define a repeatable, risk-based security review baseline for the repository.
  - Focus review effort on the directories that terminate trust boundaries or handle secrets, identity, or code execution.
  - Produce a canonical findings artifact that can be referenced by follow-up hardening changes.
  - Prevent one-off audit notes from bypassing the normal OpenSpec workflow.
- Non-Goals:
  - Fix every discovered issue inside this umbrella proposal.
  - Replace existing in-flight hardening changes that already own narrower remediation scopes.
  - Treat generated dependencies, vendored code, or build artifacts as first-class audit targets unless a finding requires that deeper review.

## Decisions
- Decision: Introduce a new `security-review-program` capability rather than overloading an authentication or onboarding spec.
  - Rationale: this change is about repository review coverage and finding management, not one service's runtime behavior.
- Decision: Split review scope into primary and secondary tiers.
  - Rationale: the repo is too large for one undifferentiated pass; the primary tier covers the most security-critical trust boundaries first.
- Decision: Require every confirmed finding to map to a disposition.
  - Rationale: untracked findings are effectively lost work. A finding must become a remediation change, merge into an active hardening change, or be documented as accepted risk.
- Decision: Keep the umbrella proposal review-only.
  - Rationale: mixing unrelated fixes into one branch would make verification, rollout, and rollback unclear.

## Risks / Trade-offs
- Review breadth can create pressure to collapse multiple unrelated fixes into one change.
  - Mitigation: require dedicated follow-up changes for confirmed issues.
- Active hardening proposals may overlap with new findings.
  - Mitigation: the review artifact must note whether a finding is already covered by an in-flight change.
- Secondary scope may slip if the primary audit expands.
  - Mitigation: primary scope completion is the explicit gate before remediation begins.

## Migration Plan
1. Approve the umbrella review proposal.
2. Produce the baseline review artifact covering the primary directories.
3. File follow-up remediation changes for uncovered high-severity issues.
4. Expand into the secondary review scope.
5. Archive the umbrella change after the review artifact and follow-up change set are complete.

## Open Questions
- Where should the long-lived review artifact live after approval: under `docs/docs/`, a dedicated `security/` directory, or under the change directory until archive time?
- Should accepted-risk entries be tracked in a dedicated repo file or only through archived OpenSpec changes?
