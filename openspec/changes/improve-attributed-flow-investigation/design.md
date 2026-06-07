## Context

Operators need attributed NetFlow records to answer two questions quickly:

- Which flows have local process/container context?
- When attribution is missing, which agent or protocol path failed?

The current page shows the raw join output and includes unmatched rows directly in
the primary table. That is useful for debugging ingestion, but it is not a good
default investigation workflow.

## Goals / Non-Goals

- Goals: fast attributed-row triage, explicit unmatched-flow gap analysis,
  deterministic pagination, controllable live updates, flow-detail drill-down,
  map attribution cues, agent provenance, rDNS, byte formatting, and CTI context.
- Non-Goals: changing the eBPF attribution backend, solving ICMP tuple extraction,
  or replacing the canonical NetFlow details model.

## Decisions

- **Attributed-first default.** The page opens on attributed rows because that is
  the primary operator workflow. Unmatched rows remain accessible through a
  deliberate filter for troubleshooting hit-rate gaps.
- **Live mode is opt-in-controllable.** The page follows the observability logs
  pattern: live updates can be enabled for monitoring or disabled while an
  operator is inspecting a page/details view.
- **Rows are summaries, details carry depth.** The table should not horizontally
  scroll to expose every raw field. It shows concise endpoint/process/agent/status
  data, then drills into NetFlow details for full payload/context.
- **Shared enrichment helpers.** Reverse-DNS and CTI/OTX state should reuse
  existing ServiceRadar enrichment paths where possible. New shared helpers are
  acceptable only when they remove duplicated UI-specific lookup code.
- **Map and table share detail semantics.** Clicking an attributed map path and
  clicking a table row should land in the same flow details experience.

## Risks / Trade-offs

- rDNS and CTI lookups can add latency if done per row; queries should batch/cache
  enrichment or use existing projections rather than performing per-cell network
  work.
- Live updates can shift row positions during investigation; the live toggle must
  preserve page/filter state when disabled.
- Showing unmatched rows by default can make attribution look worse than it is;
  hiding them entirely removes useful debugging. The default attributed filter and
  explicit unmatched card balance both needs.
