# Change: Add God-View Topology Platform

## Why
Operators currently pivot across multiple screens to correlate topology state, traffic behavior, and incident causality. Issue #2834 defines a unified "God-View" experience that can render very large graphs and highlight causal blast radius in near real time.

## What Changes
- Add a new `topology-god-view` capability that defines end-to-end requirements for large-scale topology visualization in web-ng.
- Define a binary topology snapshot contract (Arrow IPC payload plus metadata) for high-throughput node/edge streaming.
- Define a hybrid filtering model where backend causal logic emits compact node-state bitmasks and frontend GPU rendering applies visual ghosting/highlighting.
- Define a causal attribution requirement that classifies root-cause vs affected nodes and exposes operator-visible reasoning.
- Add semantic zoom and structural reshape requirements so topology can move between global and local views without losing causal context.
- Gate the capability behind a feature flag with phased rollout and explicit performance SLOs.

## Impact
- Affected specs: `topology-god-view` (new)
- Affected code:
  - `web-ng` topology visualization UI/live components and channel/event plumbing
  - `elixir/serviceradar_core` topology projection and stream orchestration
  - `rust/*` NIF/processing modules for snapshot packing and causal evaluation
  - AGE/CNPG-backed topology data access and projection paths
