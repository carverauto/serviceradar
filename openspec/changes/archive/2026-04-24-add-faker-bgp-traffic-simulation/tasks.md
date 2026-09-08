## 1. Simulator Architecture
- [x] 1.1 Define faker config schema for BGP simulation profiles, peers, prefixes, and scenario schedules.
- [x] 1.2 Add a dedicated BGP simulation module under faker with clear interfaces and lifecycle hooks.
- [x] 1.3 Preserve existing Armis faker behavior as default when BGP simulation is disabled.

## 2. Event Generation and Scenarios
- [x] 2.1 Implement steady-state route advertisement generation (IPv4 + IPv6) via GoBGP.
- [x] 2.2 Implement route withdrawal and re-advertisement cycles via GoBGP.
- [ ] 2.3 Implement peer outage simulation (peer down/up) with configurable randomization windows and BMP continuity checks.
- [x] 2.4 Add deterministic seed support for reproducible demo runs.

## 3. FRR-Aligned Demo Profile
- [x] 3.1 Add default demo profile reflecting ASN `401642`, internal peer sets, and ISP peers from provided FRR config.
- [x] 3.2 Add advertised prefix defaults `23.138.124.0/24` and `2602:f678::/48`.
- [ ] 3.3 Validate generated topology metadata is sufficient for causal state-change testing.

## 4. Deployment Wiring
- [x] 4.1 Add demo environment config knobs (Helm and/or compose overlay) to enable BGP simulation.
- [ ] 4.2 Add operational docs for starting, pausing, and tuning scenarios in demo.
- [x] 4.3 Ensure default production-like stacks remain unchanged unless explicitly enabled.

## 5. Validation
- [x] 5.1 Add unit tests for event scheduler, scenario transitions, and profile parsing.
- [ ] 5.2 Add integration smoke test proving BMP is received by Arancini and causal state transitions follow simulated outages.
- [x] 5.3 Run `openspec validate add-faker-bgp-traffic-simulation --strict`.
