# Change: Fix agent operations and Proxmox discovery UX

## Why
The current demo build exposes several operator-facing gaps in the agent and Proxmox workflow: `/agents` is reachable only by manual URL entry and fails when SRQL queries the removed `ocsf_agents.ip` column, agent detail pages hide or stale-render release and service-check data, credential rule scoping is ambiguous, and Proxmox candidates are not being discovered unless credentials already exist.

This creates a poor operational loop for Proxmox onboarding: operators cannot easily find the managing agent, cannot tell whether release management is healthy, and cannot safely discover PVE candidates before deciding where credentials should apply.

## What Changes
- Make the agent list a first-class navigation target, restore the Services navigation target in the operations sidebar, and align agent SRQL/UI fields with the stored `host` field while preserving `ip` as a compatibility alias where needed.
- Clean up Edge Ops/settings navigation so release management, plugins, and related agent operations have one clear link each with no duplicate Plugins entries.
- Hydrate agent detail pages with authoritative release rollout status, desired/current version, last update timestamps/errors, connected-session metadata, and configured service checks.
- Replace freeform agent scope entry in credential rules with an agent selector populated from registered agents, while preserving non-agent scope entry behavior.
- Automatically prune or hide stale agent registry rows from operator selection surfaces so disconnected historical agents do not pollute plugin assignment and credential-scope lists.
- Update the first-party plugin repository UI to show plugins from the latest indexed release by default, with a release selector for older releases instead of one table containing every indexed release.
- Store imported plugin package blobs in NATS Object Store as the only supported persistent backend and remove filesystem blob storage as a production/application mode.
- Fix web-ng database connection churn that produces repeated Postgrex `client exited` disconnect messages under agent/plugin/release settings workflows.
- Add SRQL search shortcuts for device searches so bare IP addresses or hostnames are translated into safe `in:devices ...` queries by the UI.
- Decouple unauthenticated Proxmox candidate discovery from credential availability; credentials are required only for authenticated Proxmox enrichment or console access.
- Make Proxmox candidate discovery scope explicit: job seeds/SRQL scope define where unauthenticated fingerprinting is allowed, and the `allow auto-discovery credential trials` setting controls only whether scoped credentials may be tried against discovered candidates.
- Ensure agent-managed devices are not reclassified as cameras solely because the agent has a camera plugin loaded or camera-related metadata.

## Impact
- Affected specs: `agent-registry`, `agent-release-management`, `build-web-ui`, `device-identity-reconciliation`, `network-discovery`, `plugin-configuration-ui`, `srql`
- Affected code:
  - `rust/srql/src/query/agents.rs`
  - `rust/srql/src/schema.rs`
  - `elixir/serviceradar_core/priv/repo/migrations/**`
  - `elixir/serviceradar_core/lib/serviceradar/infrastructure/agent.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/agent_live/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/network_credential_rules_live.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/agent_plugin_live/**`
  - `elixir/web-ng/lib/serviceradar_web_ng/plugins/storage.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/layouts.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/**`
  - `elixir/serviceradar_core/lib/serviceradar/edge/**`
  - `go/pkg/mapper/**`
