# Change: Recover partition-bound plugin assignments safely

## Why

The partition-binding migration correctly quarantined assignments whose original
partition was not trustworthy, but the first remediation exposed those database
rows as an operator work queue. That produced one warning and recovery action per
agent and package, blocked ordinary remove-and-recreate workflows, and asked users
to understand internal migration state.

The product already has stronger current evidence: live mTLS control sessions,
cryptographically verified first-party packages, current package schemas, and
authoritative policy and credential-rule reconcilers. ServiceRadar should use
those controls automatically and retain legacy rows only as hidden audit history.

## What Changes

- Run a bounded, idempotent background sweep for quarantined manual assignments.
- Automatically create a fresh partition-bound assignment only when the package
  is approved, verified, signed, first-party, content-addressed, and available in
  object storage; current mTLS evidence, schema compatibility, secret-reference
  validity, and assignment conflicts are rechecked at commit time.
- Leave uploaded, unsigned, unverified, schema-incompatible, offline, and
  conflicting rows disabled. They never become an operator click queue; an
  operator may express fresh intent through the normal assignment form.
- Let existing policy and credential-rule reconcilers restore controller-owned
  desired state from their current authoritative owner. Historical policy rows
  are never cloned and never authorize controller work.
- Keep every quarantined source row disabled and unbound as audit history and
  make recovery idempotent through the existing immutable recovery audit.
- Exclude quarantined history from normal assignment lookup and remove the legacy
  candidate table, repeated warnings, per-row review links, reapproval buttons,
  and reconciliation buttons from the Plugins UI.
- Report the release version from the immutable web deployment image tag so the
  UI cannot remain on a stale imported-agent-release value after a rollout.

## Impact

- Affected specs: `wasm-plugin-system`, `plugin-configuration-ui`,
  `ash-authorization`
- Affected code: plugin assignment recovery, the periodic plugin policy scheduler,
  assignment read adapters and Plugins LiveView, deployment environment, and
  settings status cards
- Operational impact: trusted first-party recovery is zero-touch and bounded;
  controller-owned state remains controller-owned; untrusted history fails closed
  without creating user busywork; no default partition is inferred
