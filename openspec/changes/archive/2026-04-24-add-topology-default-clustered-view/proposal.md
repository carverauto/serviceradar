# Change: Default God-View to a clustered topology summary

## Why
The current God-View topology payload can now surface many discovered endpoints, but the default graph has become too dense for operators to use. In endpoint-heavy environments, a fully expanded endpoint layer produces a large fan-out of attachment leaves that overwhelms the backbone layout, creates excessive edge crossings, and makes it harder to answer the primary question the default view should solve: how the infrastructure is connected.

We need a new default topology behavior that keeps discovered endpoints available without forcing operators to start from a graph of every leaf. The clustered default must remain backend-authored so the God-View contract stays the same: the backend decides topology projection, cluster membership, and layout coordinates; the frontend only renders the snapshot and requests explicit expansion.

## What Changes
- Add a `build-web-ui` requirement that the default God-View topology view summarizes dense endpoint attachments into backend-authored cluster nodes instead of rendering every endpoint leaf at once.
- Require cluster nodes to preserve operator context with aggregate counts and summarized state while keeping the backbone infrastructure readable.
- Require operators to have an explicit way to expand clustered endpoints on demand using a backend-authored spiral expansion around the owning infrastructure anchor, without changing the backbone contract or moving layout responsibility to the frontend.
- Require endpoint-layer toggles and cluster-expansion behavior to be compatible, so disabling endpoints still hides endpoint summaries/expansions while preserving backbone infrastructure.
- Add regression coverage for dense access-layer fixtures to ensure the default topology view remains readable when many discovered endpoints attach to the same access device.

## Impact
- Affected specs:
  - `build-web-ui`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/channels/topology_channel.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/topology_live/god_view.ex`
  - `elixir/web-ng/assets/js/lib/god_view/*`
  - God-View backend/frontend/channel regression tests

## Dependencies
- Builds on `add-topology-endpoint-visibility` and assumes discovered endpoint attachments already survive the canonical topology pipeline.
