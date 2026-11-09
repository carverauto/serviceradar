# Recovery foundation choices

## Bound one recovery operation before granting authority

- When: registration contract pass, 2026-11-09.
- Choice: register the full bounded plan before issuing page or copy authority.
  If an agent loses sequences 9 and 11 while preserving 10, registration must
  carry both loss spans and the intended destination of 10. An interval alone
  could falsely describe 10 as lost. The gateway can check the complete plan
  without reconstructing the agent's erased journal evidence; the agent still
  owns the separate proof that its destination copy committed.
- Gap: the approved design requires operation-specific authority and a bounded
  terminal copy manifest but leaves the request shape and operation size open.
- Reach: select at most 1024 allocated slots per operation, with the existing
  256 KiB exact manifest limit and a 512 KiB registration limit. Larger plans
  split into distinct recoveries before freezing IDs. Four authenticated RPCs
  separate registration, source authorization, copy grant renewal and completion
  query. Protocol version zero keeps older or incomplete peers inactive.
- Verdict: sound. These bounds limit work without deleting evidence or widening
  loss spans; they leave local durability and consumer commit as separate gates.
- Confidence: medium. End-to-end reserve sizing must still demonstrate progress
  for large individual records; the slot limit is a ceiling, not a target size.

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
