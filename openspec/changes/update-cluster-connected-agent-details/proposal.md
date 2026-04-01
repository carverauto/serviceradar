# Change: Update cluster connected agent details

## Why

The `/settings/cluster` page currently shows only a minimal connected agent summary. Operators using the cluster settings page to debug rollouts, mixed-platform fleets, and gateway connectivity cannot see the runtime details they need, such as agent version, OS, architecture, or gateway association, without navigating to other pages or querying the backend directly.

## What Changes

- Extend the connected-agent data shown on `/settings/cluster` so the "Connected Agents" card includes runtime metadata such as version, OS, architecture, and related identity details when available.
- Preserve the additional connected-agent metadata in the cluster page's agent cache so refreshes and reconnects do not drop those fields.
- Define how missing metadata is presented so operators can distinguish unknown values from disconnected agents.

## Impact

- Affected specs: `agent-registry`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/agent_tracker.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/cluster_live/index.ex`
  - associated web-ng LiveView tests for `/settings/cluster`
