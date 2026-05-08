## 1. Agent SRQL and Navigation
- [x] 1.1 Restore/add `ocsf_agents.ip` through an Elixir migration and update the Agent Ash resource.
- [x] 1.2 Populate `host` and `ip` separately from agent registration/control-stream metadata.
- [x] 1.3 Change SRQL agent projection/filtering to read both `ocsf_agents.host` and `ocsf_agents.ip`.
- [x] 1.4 Update web SRQL catalog/builder fields so agent searches support both `host` and `ip`.
- [x] 1.5 Add Agents to the authenticated operations navigation and verify `/agents` is reachable without manual URL entry.
- [x] 1.6 Restore Services in the authenticated operations navigation and verify `/services` is reachable without manual URL entry.
- [x] 1.7 Clean up Edge Ops/settings navigation so `/settings/agents/releases` has one Plugins link and one clear Releases link.
- [x] 1.8 Add focused SRQL tests for `in:agents`, `host`, and `ip` behavior.

## 2. Agent Detail Status
- [x] 2.1 Hydrate release management fields from persisted agent state, latest rollout targets, and live control-stream metadata.
- [x] 2.2 Clear stale `last_update_error` when agents reconnect or report successful update/healthy state.
- [x] 2.3 Populate Service Checks on agent detail from effective service/check registrations for that agent.
- [x] 2.4 Add LiveView tests for release fields and service check rendering.

## 3. Credential Rule UX
- [x] 3.1 Render `scope_value` as an agent dropdown when `scope_type=agent`.
- [x] 3.2 Preserve freeform input for gateway and partition scopes.
- [x] 3.3 Exclude stale/inactive agent rows from agent scope selection unless explicitly viewing historical agents.
- [x] 3.4 Add LiveView tests for agent-scope selection and form change behavior.

## 4. Agent and Plugin Settings Cleanup
- [x] 4.1 Add an Ash/Oban stale-agent pruning job or equivalent scheduled cleanup for superseded/offline historical agent rows.
- [x] 4.2 Filter plugin assignment agent selectors to active/recent registered agents.
- [x] 4.3 Update first-party repository plugin UI to show the latest indexed release by default.
- [x] 4.4 Add a release selector for viewing plugins from older indexed releases.
- [x] 4.5 Remove filesystem plugin blob storage as an application backend and use NATS Object Store for imported plugin blobs.
- [x] 4.6 Update Helm/demo configuration to use NATS Object Store for plugin storage.
- [x] 4.7 Add tests for stale-agent filtering, latest-release plugin listing, and NATS Object Store plugin storage.

## 5. SRQL Search Shortcuts
- [x] 5.1 Add UI-side shortcut detection for bare IP addresses and hostnames in device SRQL inputs.
- [x] 5.2 Translate shortcuts into explicit `in:devices ip:<value>` or hostname/name search SRQL before execution.
- [x] 5.3 Ensure shortcuts work from device list and device detail pages and navigate to the correct results page.
- [x] 5.4 Add tests for shortcut translation and detail-page SRQL submit navigation.

## 6. Proxmox Candidate Discovery
- [x] 6.1 Allow mapper Proxmox candidate fingerprinting without an existing Proxmox credential rule when enabled by job scope/settings.
- [x] 6.2 Keep authenticated credential trials disabled unless the credential rule explicitly enables auto-discovery trials.
- [x] 6.3 Record candidate evidence metadata (`port`, `title`, `fingerprint_source`, `observed_at`) without credentials.
- [x] 6.4 Add mapper tests for credential-free candidate marking and scoped credential trial gating.
- [x] 6.5 Trigger the scoped demo mapper job for `agent-sr-test-pve04` and verify candidate rows appear in SRQL.

## 7. Device Classification
- [x] 7.1 Prevent camera ingestion from reclassifying agent-managed host devices as cameras.
- [x] 7.2 Ensure agent gateway sync restores agent-managed devices to server/agent-host classification when needed.
- [x] 7.3 Add regression tests for an agent host that also runs a camera plugin.

## 8. Validation
- [x] 8.1 Run `openspec validate fix-agent-discovery-operations-ux --strict`.
- [x] 8.2 Run focused Rust SRQL tests.
- [x] 8.3 Run focused web-ng LiveView tests.
- [x] 8.4 Run focused core/gateway agent sync tests.
- [x] 8.5 Verify web-ng logs no longer emit repeated Postgrex `client exited` disconnect churn during plugin import and agent settings page loads.
- [x] 8.6 Deploy to demo and verify the reported URLs and `agent-sr-test-pve04` workflow.
