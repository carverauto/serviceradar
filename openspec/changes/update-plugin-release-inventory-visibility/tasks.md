## 1. Release Inventory Cleanup
- [ ] 1.1 Cap published agent releases displayed in release management to the latest five entries.
- [ ] 1.2 Cap discovered repository releases displayed in release management to the latest five entries.
- [ ] 1.3 Ensure repository release discovery does not fetch or render unbounded release history for the release-management UI.
- [ ] 1.4 Enable demo object-store retention with destructive cleanup enabled and `agentReleaseKeepLatest: 5`.
- [ ] 1.5 Add/update tests for latest-five published and repository release display.

## 2. First-party Plugin Repository UI
- [ ] 2.1 Keep the First-party Repository Plugins release selector in the table header.
- [ ] 2.2 Paginate selected first-party repository plugin entries ten rows at a time.
- [ ] 2.3 Add LiveView coverage proving a catalog with more than ten plugins renders page one and page two correctly.

## 3. Wasm Plugin Service Visibility
- [ ] 3.1 Trace current assigned-plugin execution to service status publication for UniFi, AlienVault, and other health-producing Wasm plugins.
- [ ] 3.2 Define a stable service identity for each plugin assignment, including service name, plugin ID, agent, gateway, partition, and assignment/package provenance.
- [ ] 3.3 Ensure successful, warning, unknown, and failed plugin executions publish `GatewayServiceStatus` or equivalent service status records consumed by `/services`.
- [ ] 3.4 Ensure stale or missing plugin execution status is visible as stale/unknown rather than silently absent.
- [ ] 3.5 Add regression coverage that an assigned plugin appears in the services list after the agent reports plugin status.

## 4. Documentation and Validation
- [ ] 4.1 Document the release/plugin inventory limits and object-store retention behavior.
- [ ] 4.2 Document the Wasm plugin service visibility contract for plugin authors/operators.
- [ ] 4.3 Run focused web-ng tests for release/plugin inventory.
- [ ] 4.4 Run focused agent/gateway/service status tests for plugin service publication.
- [ ] 4.5 Run `openspec validate update-plugin-release-inventory-visibility --strict`.
