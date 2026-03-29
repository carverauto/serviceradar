## 1. Review Baseline
- [ ] 1.1 Create the baseline security review inventory for the repository trust boundaries and review tiers.
- [ ] 1.2 Record the primary audit scope directories and the secondary follow-on audit scope directories in the review artifact.
- [ ] 1.3 Define the review output format for findings, including severity, exploitability, affected paths, remediation guidance, and disposition.

## 2. Primary Audit Pass
- [ ] 2.1 Review `elixir/web-ng/lib` for authentication, authorization, token, upload/download, outbound fetch, and admin/API issues.
- [ ] 2.2 Review `elixir/serviceradar_core/lib`, `elixir/serviceradar_agent_gateway/lib`, and `elixir/serviceradar_core_elx/lib` for policy bypasses, onboarding/certificate issues, trust-boundary validation gaps, and internal service exposure risks.
- [ ] 2.3 Review `go/pkg/agent`, `go/pkg/edgeonboarding`, `go/pkg/grpc`, and `go/pkg/config/bootstrap` for update/runtime/plugin/bootstrap/TLS weaknesses.
- [ ] 2.4 Review `rust/edge-onboarding`, `rust/config-bootstrap`, and `helm/serviceradar` for onboarding-token, bootstrap, secret, certificate, and deployment exposure risks.

## 3. Secondary Audit Pass
- [ ] 3.1 Review the secondary Go, Rust, Docker, Kubernetes, and TLS directories defined by the proposal.
- [ ] 3.2 Cross-check secondary findings against primary trust boundaries to avoid duplicate remediation changes.

## 4. Findings And Follow-Up
- [ ] 4.1 Produce the canonical security review artifact with complete coverage and findings status.
- [ ] 4.2 Map each confirmed finding to either a dedicated remediation change, an existing in-flight hardening change, or an explicitly accepted risk entry.
- [ ] 4.3 Open follow-up OpenSpec changes for confirmed high-severity issues that are not already covered.

## 5. Verification
- [ ] 5.1 Run `openspec validate add-repo-security-review-baseline --strict`.
- [ ] 5.2 Confirm the review artifact covers every primary scope directory before starting remediation work.
