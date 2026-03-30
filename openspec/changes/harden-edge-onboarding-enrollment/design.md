## Context
Edge onboarding is a privileged bootstrap path. The token and bundle download flow ultimately writes service configuration and credentials onto the target host, then restarts the agent. That path currently trusts unsigned token metadata and uses insecure transport defaults.

## Goals / Non-Goals
- Goals:
  - Ensure clients detect tampered onboarding tokens before trusting embedded metadata.
  - Ensure HTTPS and certificate verification are the default for bundle download.
  - Keep legacy compatibility explicit without preserving an insecure transport path.
- Non-Goals:
  - Redesigning the entire edge onboarding package resource model.
  - Replacing download tokens or package delivery semantics in Core.
  - Changing the release artifact gateway-delivery model.

## Decisions
- Decision: add integrity protection to structured onboarding tokens.
  - Rationale: the embedded `api` URL is a trust-bearing field and must not be attacker-editable.
- Decision: remove insecure transport support from `serviceradar-cli enroll`.
  - Rationale: enrollment is a privileged bootstrap path and does not justify a TLS-bypass flag.
- Decision: require HTTPS for remote bundle download by default.
  - Rationale: onboarding is a credential/bootstrap path, not a best-effort fetch.
- Decision: treat unsigned `edgepkg-v1` tokens as a legacy compatibility format that cannot supply a trusted Core API endpoint.
  - Rationale: legacy tokens may still exist during rollout, but they cannot remain a trust anchor.

## Risks / Trade-offs
- Existing ad hoc tokens or copy/paste workflows may need regeneration after the new format ships.
  - Mitigation: document the migration path and keep compatibility behavior explicit where safe.
- Tightening transport defaults may surface previously hidden misconfiguration in test environments.
  - Mitigation: require valid HTTPS and CA configuration in every environment, including test.
