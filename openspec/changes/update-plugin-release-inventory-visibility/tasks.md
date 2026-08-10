## 1. Release Inventory Cleanup
- [x] 1.1 Cap published agent releases displayed in release management to the latest five entries.
- [x] 1.2 Cap discovered repository releases displayed in release management to the latest five entries.
- [x] 1.3 Ensure repository release discovery does not fetch or render unbounded release history for the release-management UI.
- [x] 1.4 Enable demo object-store retention with destructive cleanup enabled and `agentReleaseKeepLatest: 5`.
- [x] 1.5 Add/update tests for latest-five published and repository release display.

## 2. First-party Plugin Repository UI
- [x] 2.1 Keep the First-party Repository Plugins release selector in the table header.
- [x] 2.2 Paginate selected first-party repository plugin entries ten rows at a time.
- [x] 2.3 Add LiveView coverage proving a catalog with more than ten plugins renders page one and page two correctly.
- [x] 2.4 Review the installed Plugin Packages table for bounded display/pagination and avoid presenting object-store history as if every retained blob is a recommended active version.

## 3. Wasm Plugin Service Visibility
- [x] 3.1 Trace current assigned-plugin execution to service status publication for UniFi, AlienVault, and other health-producing Wasm plugins.
- [x] 3.2 Define a stable service identity for each plugin assignment, including service name, plugin ID, agent, gateway, partition, and assignment/package provenance.
- [x] 3.3 Ensure successful, warning, unknown, and failed plugin executions publish `GatewayServiceStatus` or equivalent service status records consumed by `/services`.
- [x] 3.4 Ensure stale or missing plugin execution status is visible as stale/unknown rather than silently absent.
- [x] 3.5 Add regression coverage that an assigned plugin appears in the services list after the agent reports plugin status.
- [x] 3.6 Normalize plugin result statuses from SDK/sample plugins so `failed` is accepted or mapped to the canonical failed/critical status instead of producing `plugin status invalid`.

## 4. Documentation and Validation
- [x] 4.1 Clean up device details metadata cards: group SNMP, Armis, UniFi, MikroTik, Proxmox, NetBox, and discovery metadata into source-specific sections.
- [x] 4.2 Remove redundant aliases/opaque "other metadata" summaries when the same data is already shown in richer tables.
- [x] 4.3 Render uptime and timestamps as readable dates/durations.
- [x] 4.4 Add Armis risk score visual treatment and display active/in-service state consistently.
- [x] 4.5 Ensure Armis-enriched device type/category populate canonical OCSF type fields when stronger local evidence is absent.
- [x] 4.6 Make the device Logs tab run a bounded SRQL/device-log query and show an immediate zero-row empty state when no logs exist.
- [x] 4.7 Fix Agent Availability card source labeling so recent per-agent sweep history is reflected rather than showing fallback/no-data.

## 5. Northbound Action UX and Target Context
- [x] 5.1 Ensure action launch feedback tells operators where results appear and refreshes Action History without blocking LiveView events.
- [x] 5.2 Remove meaningless `nil` fields from Action History target/result summaries.
- [x] 5.3 Ensure interface action target snapshots include interface name, ifIndex, and physical naming/module context when available.
- [x] 5.4 Let plugin contracts choose supported device/interface fields instead of hard-coding brittle target payload shapes.
- [x] 5.5 Add regression coverage for numeric/string field mismatches in target snapshots.
- [x] 5.6 Fix demo action-launch authorization so users with the intended role can launch device/interface actions, and unauthorized users get a precise `northbound.actions.launch` message.

## 6. Agent Rollout Status Semantics
- [x] 6.1 Trace `command_ack_timeout` handling for agents that restart after dispatch but later activate successfully.
- [x] 6.2 Ensure late reconnect/activation success supersedes transient ack-timeout progress text and clears stale last-error display.
- [x] 6.3 Add rollout-state tests for dispatch timeout followed by successful activation.
- [x] 6.4 Fix agent details desired-version derivation so stale failed rollout attempts do not override the current desired version or a newer successful activation.

## 7. NetFlow and Topology Regression Diagnostics
- [x] 7.1 Investigate why `/dashboard` reports no NetFlow paths despite recent flow conversations.
- [x] 7.2 Verify GeoIP enrichment and private-network anchor joins still provide coordinates for mapped paths.
- [x] 7.3 Investigate topology backbone islands against expected AGE canonical adjacency.
- [x] 7.4 Add diagnostic counters or validation queries for missing canonical edges, unresolved endpoints, stale-edge pruning, and anchor gaps.
- [x] 7.5 Add regression coverage or replay fixtures that preserve expected backbone connectivity.

## 8. Documentation and Validation
- [x] 8.1 Document the release/plugin inventory limits and object-store retention behavior.
- [x] 8.2 Document the Wasm plugin service visibility contract for plugin authors/operators.
- [x] 8.3 Document device-details metadata grouping and action-result location semantics.
- [x] 8.4 Run focused web-ng tests for release/plugin inventory and device/action UI.
- [x] 8.5 Run focused agent/gateway/service status tests for plugin service publication and rollout states.
- [x] 8.6 Run focused topology/NetFlow regression checks.
- [x] 8.7 Run `openspec validate update-plugin-release-inventory-visibility --strict`.
