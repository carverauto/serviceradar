# Change: Harden DIRE identity confidence model and merge safety

## Why
Issue #2817 shows a recurring identity regression where two real devices can alternate visibility due to unstable discovery signals and over-aggressive merge behavior. Current behavior allows interface-discovered MAC evidence to participate in canonical identity too early, and allows MAC-only conflicts to trigger destructive merges. This is brittle for SNMP/LLDP topology workflows where interface observations are noisy, order-dependent, and often indirect.

## What Changes
- Introduce an evidence-first identity model in DIRE: distinguish **observations** from **canonical identifiers**.
- Make mapper interface discovery create/update **provisional inventory state** without promoting interface MACs directly into canonical `device_identifiers`.
- Require corroboration before promoting weak evidence (for example repeated sightings and at least one corroborating stable signal).
- Prohibit automatic merges from MAC-only evidence sets; require at least one non-MAC strong identifier or explicit operator action.
- Define deterministic tie-break and conflict handling to avoid identity flip-flops across scans.
- Add role-aware discovery alias policy so router interface IPs remain aliases while AP/bridge client IP artifacts do not pollute device alias identity.
- Promote AP/bridge-filtered client IP observations into endpoint discovery candidates rather than dropping them.
- Add a full regression matrix for identity resolution, promotion, merge, and unmerge behavior.

## Impact
- Affected specs:
  - `device-identity-reconciliation`
  - `network-discovery`
- Affected code (expected):
  - `elixir/serviceradar_core/lib/serviceradar/inventory/identity_reconciler.ex`
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_results_ingestor.ex`
  - `elixir/serviceradar_core/lib/serviceradar/identity/*`
  - `elixir/serviceradar_core/test/serviceradar/inventory/*`
  - `elixir/serviceradar_core/test/serviceradar/network_discovery/*`
- Data model impact:
  - May require explicit identity-evidence state/metadata and promotion timestamps
- **BREAKING (behavioral):** automatic MAC-only merges are removed; evidence promotion rules become stricter.
