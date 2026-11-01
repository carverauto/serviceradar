# Change: Manage component certificates and enforce operator revocation

## Why

Edge deployments need an enrolled ServiceRadar agent alongside each NATS leaf
host and collector host. Operators need automatic certificate maintenance and
an effective UI kill switch for individual components and whole sites, including
trusted-side enforcement in NATS, core, and agent-gateway.

Existing agent renewal, CSR issuance, atomic certificate installation, certificate
metadata, and expiry alerts provide a foundation. Durable cross-gateway revocation
and individual NATS leaf revocation remain deferred in issue #5257 and
`add-agent-certificate-renewal` tasks 2.1b/2.3. The current gateway denylist is
process-local ETS. Collector revoke actions update records and broadcast events;
that alone is not evidence that NATS rejects an issued credential.

## What Changes

- Require an enrolled agent on every managed leaf/collector host; the optional
  edge agent-gateway remains optional.
- Bind a distinct certificate identity to each managed component, with separate
  leaf upstream-client and local-server credentials. Extend the agent's existing
  renewal and atomic installation machinery to supported collector services.
- Make CLI onboarding preflight the deployment's NATS authentication mode and
  account readiness. Provision component access through the control plane; keep
  account/operator signing authority off edge hosts. Do not introduce per-customer
  accounts or multitenancy into a deployment.
- Implement the existing durable revocation design and synchronize enforcement
  across all applicable gateways, core services, and NATS boundaries. Cover both
  client and server certificate use, active connections, reconnect, and renewal.
- Add certificate inventory and scoped Revoke, Rotate, and Re-enroll UI actions,
  with pending/enforced/failed status rather than success based on a DB update.
- Prove isolated revocation and rotation end to end before beta signoff.
- Managed leaf and collector certificates are ordinary PKIX certificates,
  identified by stored fingerprints and explicit permissions. This path does
  not use SPIRE or a required SPIFFE URI. Hub observation of a presented leaf
  certificate comes from an authenticated NATS connection listing. The chart
  keeps authorization callout disabled until operator adoption.

## Impact

- Affected specs: new `component-certificate-lifecycle`, composed with
  `agent-connectivity`, `edge-onboarding`, and `edge-architecture`.
- Reuses `add-agent-certificate-renewal` and completes the revocation work tracked
  by https://github.com/carverauto/serviceradar/issues/5257; it does not duplicate
  the agent self-renewal implementation or unrelated estate cleanup work.
- Affected code: agent renewal and managed-service lifecycle, certificate issuer,
  Ash certificate/revocation resources, NATS authorization integration, gateway
  identity checks, core transport validation, CLI onboarding, and operator UI.
- **BREAKING for new managed installs:** unmanaged leaf/collector hosts must enroll
  an agent. Existing installations receive an explicit adoption path.
- This is a proposal. Protocol selection and runtime changes are not shipped.
