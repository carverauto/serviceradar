# Change: Add Repository Security Review Baseline

## Why
ServiceRadar has accumulated many security-sensitive trust boundaries across `web-ng`, `serviceradar_core`, `agent-gateway`, `core-elx`, the Go agent runtime, edge onboarding, SPIFFE/mTLS bootstrap, and Helm/Kubernetes deployment assets. There are already several targeted hardening changes in flight, but the repository does not have a single approved review baseline that defines which directories must be audited, what artifacts the audit must produce, or how confirmed findings are turned into tracked remediation work.

Without an umbrella proposal, security review remains ad hoc: high-risk paths can be missed, findings can be rediscovered repeatedly, and follow-up fixes can be mixed together without a clear scope or acceptance trail.

## What Changes
- Add a repository-level security review program that defines the baseline audit scope for the highest-risk directories and secondary review tiers.
- Require the review to be driven by trust boundaries: authentication, authorization, token handling, certificate issuance, onboarding/bootstrap, agent runtime/plugin execution, external fetches, database access, and deployment exposure.
- Require a canonical security review artifact that records review coverage, findings, severity, affected files/directories, exploit preconditions, and remediation recommendations.
- Require every confirmed finding to be dispositioned as either:
  - a dedicated follow-up OpenSpec hardening change,
  - an update to an existing in-flight hardening change, or
  - an explicitly documented accepted risk.
- Keep the umbrella change focused on review coverage and finding management; do not mix unrelated code remediations directly into this proposal.

## Impact
- Affected specs: `security-review-program` (new)
- Affected code:
  - Primary audit scope:
    - `elixir/web-ng/lib`
    - `elixir/serviceradar_core/lib`
    - `elixir/serviceradar_agent_gateway/lib`
    - `elixir/serviceradar_core_elx/lib`
    - `go/pkg/agent`
    - `go/pkg/edgeonboarding`
    - `go/pkg/grpc`
    - `go/pkg/config/bootstrap`
    - `rust/edge-onboarding`
    - `rust/config-bootstrap`
    - `helm/serviceradar`
  - Secondary audit scope:
    - `go/pkg/datasvc`
    - `go/pkg/nats`
    - `go/pkg/spireadmin`
    - `go/pkg/trivysidecar`
    - `go/pkg/scan`
    - `go/cmd/wasm-plugins`
    - `rust/trapd`
    - `rust/log-collector`
    - `rust/consumers/zen`
    - `rust/flowgger`
    - `rust/srql`
    - `docker/compose`
    - `k8s/demo`
    - `k8s/sr-testing`
    - `k8s/external-dns`
    - `k8s/argocd`
    - `tls`

## Notes
- Existing hardening changes remain the source of truth for their specific remediation scopes. This proposal adds the missing review baseline and finding-management process around them.
- Follow-up implementation changes should stay small and trust-boundary specific rather than collapsing all fixes into one branch.
