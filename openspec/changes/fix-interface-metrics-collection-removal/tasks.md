## 1. Investigation
- [ ] 1.1 Identify current interface metrics selection persistence and composite group lifecycle.
- [ ] 1.2 Trace SNMP checker config generation and refresh paths for interface metrics.

## 2. Core config + persistence
- [ ] 2.1 Persist interface metrics selections and clear them on disable.
- [ ] 2.2 Remove composite groups when metrics are disabled for an interface.
- [ ] 2.3 Emit config invalidation / version change for affected agents.

## 3. Collector behavior
- [ ] 3.1 Ensure SNMP checker drops removed metrics on config refresh.
- [ ] 3.2 Add tests for enable/disable transitions (error counters included/excluded).

## 4. UI behavior
- [ ] 4.1 Update interface details toggle to persist disable and reflect state.
- [ ] 4.2 Hide metrics charts/indicators when metrics are disabled.
- [ ] 4.3 Add UI coverage for disabling metrics.
