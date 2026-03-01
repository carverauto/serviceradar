## 1. Spec And Design
- [x] 1.1 Review existing NetFlow dashboard + SRQL flow query shapes to ensure new charts are SRQL-driven
- [x] 1.2 Define "application" semantics for NetFlow (service-by-port baseline + override precedence)
- [x] 1.3 Decide on performance strategy: query-time classification vs persisted label vs rollups (document tradeoffs)

## 2. CNPG / Timescale Changes
- [x] 2.1 Add migration for `platform.netflow_app_classification_rules` (admin-managed override rules)
- [x] 2.2 Add indexes to keep rule evaluation fast (by port/protocol, optional CIDR match, partition)
- [ ] 2.3 (Optional) Add continuous aggregate(s) for `activity by application` time-series

## 3. SRQL Enhancements
- [x] 3.1 Add `app:` filter token for `in:flows` (string label)
- [x] 3.2 Add `stats:... by app` group-by support for `in:flows`
- [x] 3.3 Add SRQL tests for application filter + group-by translation

## 4. Application Classification
- [x] 4.1 Implement baseline classification from protocol + port (use existing service tagging if present)
- [x] 4.2 Implement rule override application at query time (deterministic precedence, bounded cost)
- [x] 4.3 Add admin UI for managing classification rules (RBAC-gated)
- [x] 4.4 Add a small default ruleset (common services) and document how to extend it

## 5. Web-NG UI Enhancements (NetFlows)
- [x] 5.1 Add "Activity by protocol" stacked area chart (SRQL-driven)
- [x] 5.2 Add "Frequent talkers" tables:
  - [x] Frequent Talkers (Packet Count)
  - [x] Frequent Talkers (Byte Volume)
- [x] 5.3 Add "Activity by application" stacked area chart (SRQL-driven) with legend on the right
- [x] 5.4 Add drilldowns: clicking chart series or table row applies SRQL filters (`protocol:`, `app:`, `src_ip:`/`dst_ip:`)
- [x] 5.5 Ensure all of the above are shareable and URL-addressable (no hidden state)

## 6. Validation
- [x] 6.1 Run `openspec validate add-netflow-application-analytics --strict`
- [x] 6.4 Run repo CI checks locally (`make lint`, `make test`)
- [ ] 6.2 Add or extend tests covering:
  - SRQL builder safety when `app:` is present
  - LiveView rendering for new widgets
- [ ] 6.3 Validate performance on a large flow dataset (EXPLAIN for the app chart query shape)

## 7. Demo Deployment Validation (Post-Approval)
- [ ] 7.1 Deploy to demo and verify charts render for `time:last_1h` and `time:last_24h`
- [ ] 7.2 Verify application legend ordering is stable and drilldowns work
