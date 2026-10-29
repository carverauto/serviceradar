# Farm canary implementation choices

This records decisions made while implementing the maintainer's 2026-10-28
request for a running farm01 end-to-end sweep within 24 hours.

## Sound

- **First acceptance is a current-epoch primary sweep (high confidence).**
  Broader producer support, audit routes and the failure matrix remain pending.
  This follows the maintainer's requested focus; it does not claim M2 or M3 done.
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
  Historical issuer/scope retention and audit publication are not part of this
  pass; rotating either with outstanding spool records can withhold delivery.
- **Cap append growth before implementing reclamation (high confidence).**
  The initial sender persists terminal dispositions and a resolved prefix.
  It refuses new appends at the byte limit; it does not yet reclaim physical
  segment bytes. This permits a bounded first run, not an unattended soak, and
  leaves M2.5 incomplete.
- **Project complete terminal ICMP/TCP windows (high confidence).**
  The producer supplies every signed target and attempted check, including
  unavailable hosts. The projector rejects partial-mode/MTR windows instead
  of presenting incomplete host evidence as a finished sweep.
- **Consume a slot before its first append attempt (medium confidence).**
  Configuration and scan failures before publication can retry. After the
  durable claim, the agent does not rescan an interrupted slot and produce
  different bytes at the same execution coordinates. A first-append capacity
  or I/O failure can therefore leave a consumed slot with zero rows. The run
  remains incomplete; resumable partial executions are outside this pass.
