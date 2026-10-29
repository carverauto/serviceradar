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
