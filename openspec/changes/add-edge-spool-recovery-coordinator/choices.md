# Recovery foundation choices

## Generation configuration factory

- When: lane foundation pass, 2026-11-09.
- Choice: configure a generation with existing spool options before opening it.
  When an agent restarts after re-enrollment, an old generation still belongs to
  its original authenticated identity. The factory receives a copy of that
  identity and the generation's final directory, so its binding reader can find
  the old evidence before the spool classifies records. A single inspector bound
  to the current session would inspect old records under the wrong identity.
- Gap: the approved design requires generation-specific bindings and a shared
  allocator but did not prescribe their configuration API.
- Reach: `WithGenerationOptions` returns ordinary `spool.Option` values; future
  runtime wiring shares its allocator and admission policy through that factory.
  Factories may run concurrently across lanes. They do not acquire resources
  needing a separate cleanup callback; the caller owns such services. A factory
  error refuses the generation open rather than silently dropping its options.
- Verdict: sound. The root implementer approved this seam before implementation;
  it keeps the existing spool configuration as the single owner of those knobs.
- Confidence: high.

## Fresh filesystem probe at admission

- When: lane foundation pass, 2026-11-09.
- Choice: use the existing gopsutil disk dependency to measure free bytes at the
  configured spool directory on every allocator probe. If another process fills
  the filesystem, a nominal spool budget alone cannot protect recovery space.
  The allocator now sees that shortage and refuses ordinary writes; if the path
  cannot be measured, recovery acquisition also refuses instead of assuming
  space exists. The existing allocator owns the reserve and in-flight arithmetic.
- Gap: the allocator already accepted a free-space probe, but production did not
  supply one and the design did not choose a platform implementation.
- Reach: the agent gains a direct Bazel dependency on a disk library already in
  its dependency graph, with no version change. The probe is bound to the same
  directory the spool opened. It does not cache a startup free-space value or
  inspect a parent directory that might belong to a different filesystem.
- Verdict: sound. This reuses the repository's existing platform support while
  activating its existing fail-closed capacity contract.
- Confidence: high.
