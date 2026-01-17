# Change: Publish architecture blog for Phoenix + Rustler + CNPG pivot

## Why
Staging now runs the Phoenix/LiveView `web-ng` app with the SRQL parser embedded via Rustler and targets CNPG (TimescaleDB + Apache AGE) directly. We need a public-facing blog post that explains the consolidation from the old Next.js + Kong + standalone SRQL service to the new, simplified stack and clarifies what is shipped versus still in progress (e.g., `pg_notify`-driven push updates).

## What Changes
- Add a Docusaurus blog post (`docs/blog/2025-12-16-simplifying-observability-elixir-rustler-cnpg.mdx`) with the provided slug/title/tags and an updated narrative that reflects the current staging architecture.
- Highlight shipped capabilities: Phoenix LiveView UI, Rustler NIF wrapping the SRQL translator, direct CNPG access (Timescale hypertables + AGE graph), and Go core as orchestrator/ingestor.
- Call out near-term work (pg_notify-driven LiveView pushes) as planned, not yet shipped.

## Impact
- Affected specs: `docs-blog` (new capability)
- Affected code: `docs/blog/2025-12-16-simplifying-observability-elixir-rustler-cnpg.mdx`
- No runtime or API changes; documentation-only.
