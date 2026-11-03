# Farm canary implementation choices

This records decisions made while implementing the maintainer's 2026-10-28
request for a running farm01 end-to-end sweep within 24 hours.

## Sound

- **First acceptance is a current-epoch primary sweep (high confidence).**
  Broader producer support and the failure matrix remained pending for this
  pass. The narrowed audit and security-quarantine routes have since landed
  (`docs/edge-record-quarantine-runbook.md`). This follows the maintainer's
  requested focus; it does not claim M2 or M3 done.
- **Use existing agent-scoped lease settings (high confidence).** They already
  select a canary without enabling leasing for the deployment. Helm enables
  the transport; core settings select which agent actually receives authority.
- **Keep issuer seed custody on core (high confidence).** The chart extends the
  existing secret generator and mounts one key, read-only, on core. Gateways
  receive only public trust over the existing authenticated core connection.
- **Share one explicit installation registry (medium confidence).** Helm
  supplies identical JSON to core and gateway and rejects an empty registry.
  This uses the existing static registry contract without adding a registry
  provisioning service during the canary pass.
- **Keep key and network scope stable during the first run (high confidence).**
  The live trust source carries the current issuer and assignment scope.
  Historical issuer/scope retention is not part of this pass; rotating either
  with outstanding spool records can withhold delivery. A stale-fence record
  that already carries a valid delivery grant is published on the audit route.
- **Cap append growth (high confidence).** New appends still stop at the byte
  limit. What the sender reclaims is M2.5 in `tasks.md`. This bounds a run; it
  is not an unattended soak.
- **Project complete terminal ICMP/TCP windows (high confidence).**
  The producer supplies every signed target and attempted check, including
  unavailable hosts. The projector rejects partial-mode/MTR windows instead
  of presenting incomplete host evidence as a finished sweep.
- **Claim a leased slot before each append, and keep it only after admission (high confidence).**
  Configuration and scan failures before publication can retry. The
  operator-visible rule for a failed first append is in
  `helm/serviceradar/README.md`.

## Corrected during integration review

- **Lease storage follows the existing runtime root (high confidence).** The
  original integration left lease files outside the chart's persistent mount.
  The default resolver now honors the runtime root, and an install/reopen
  regression covers both the lease and its executed-slot marker.
- **Admission validates observations, not only claimed digests (high confidence).**
  Producer checks alone were insufficient. Projection now validates persisted
  plan pages, actual host membership and the actual check dictionary before
  writing domain state, using the existing plan/hash/CIDR implementations.
