## Context
ServiceRadar needs realistic, repeatable BGP control-plane churn for demo and validation of the new BMP+causal pipeline. Current Arancini integration scripts are useful for benchmark labs but are not integrated with the ServiceRadar demo lifecycle.

## Goals / Non-Goals
- Goals:
  - Add first-class BGP traffic simulation to `serviceradar-faker`.
  - Support deterministic and randomized scenarios for announcements, withdrawals, and neighbor flaps.
  - Feed Arancini through real BMP export from a live BGP control-plane simulator.
  - Allow demo operators to enable/disable and tune simulation from config.
- Non-Goals:
  - Building a full FRR replacement.
  - Reproducing every FRR policy primitive (route-map semantics, full prefix-list engine).
  - Replacing Arancini integration benchmarks.

## Decisions
- Decision: Implement simulator profiles in faker config with explicit peer/prefix templates.
  - Why: Keeps behavior deterministic and easy to audit in demo environments.
- Decision: Start with profile-based behavior inspired by FRR topology (ASN, peers, prefixes) and controlled event scheduler.
  - Why: Fast path to realistic data while avoiding full BGP daemon complexity.
- Decision: Use an embedded/external BGP daemon process (GoBGP) from faker and export BMP to Arancini collector.
  - Why: Preserves the production-like BGP->BMP->Arancini path and avoids direct event shortcuts.
- Decision: Generate both IPv4 and IPv6 events and include peer metadata for downstream causal correlation.
  - Why: Matches real network shape and causal use-cases.
- Decision: Keep simulator opt-in via config flags and scenario presets.
  - Why: Avoids unexpected load in environments using faker only for Armis emulation.

## Risks / Trade-offs
- Risk: Synthetic behavior diverges from production routing dynamics.
  - Mitigation: Versioned scenario profiles and golden event fixtures aligned to FRR-like topology.
- Risk: Faker service scope creep.
  - Mitigation: Isolate BGP simulator into its own package/module with clear config boundaries.
- Risk: Event flood impacts demo stability.
  - Mitigation: Rate limits, burst caps, and default conservative scenario settings.

## Migration Plan
1. Add BGP simulator config schema and defaults (disabled by default).
2. Implement scheduler-driven BGP route mutations (announce/withdraw/peer flap) through GoBGP CLI/API.
3. Add demo profile based on provided FRR configuration.
4. Wire demo deployment values and document operator runbook.
5. Validate causal pipeline behavior with deterministic scenario tests.

## Open Questions
- Which scenario controls should be surfaced in UI vs config-only for first release?
