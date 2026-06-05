## Context

Attributed flows combine two related but distinct datasets:

- NetFlow/sFlow records in `platform.ocsf_network_activity`
- Host process attribution records in `platform.flow_process_attributions`

The UI should not conflate "rows already tagged as attributed_flow" with "raw flows
that do not have process attribution." If unmatched flows are useful, they should be
presented as raw flow candidates in the same time window, with clear language and
filters. Otherwise the primary page should default to attributed-only investigation.

## Goals / Non-Goals

Goals:
- Make the page useful for repeated incident-response workflows without horizontal
  scrolling.
- Preserve normal paginated browsing by default; make live updates opt-in.
- Provide drilldown from summary cards, rows, and NetFlow map elements.
- Reuse existing enrichment sources for reverse DNS and CTI where possible.

Non-goals:
- Building a new attribution join engine in the browser.
- Blocking this UI work on perfect attribution coverage across every agent.
- Adding active DNS lookups in a LiveView render loop.

## Decisions

- **Default to attributed rows.** The first view should answer "which flows reached
  a process?" Unmatched/raw flows can be a filterable mode, but must be labeled as
  raw/unattributed candidates and should not be mixed into "Recent Attributed Flow
  Records" without explanation.
- **Use Live as an explicit mode.** Follow the logs pane contract: pagination and
  filter changes pause live mode; live mode can be re-enabled by the operator.
- **Make details the overflow path.** Table rows should stay compact: timestamp,
  endpoints with optional rDNS, protocol, human byte total, process, agent, and IOC
  indicator. PID, UID, cmdline, container ID, raw OCSF, and attribution evidence
  belong in a row detail panel/modal or details page.
- **Use shared enrichment.** Reverse DNS and CTI annotations should come from cached
  enrichment tables/services. The LiveView should not do per-render network lookups.
- **Preserve map context.** NetFlow map attribution markers should link to the same
  flow details representation as the table, so map and table investigations do not
  diverge.

## Open Questions

- Should row click open an in-page modal first, with a permanent detail URL as a
  secondary action, or should every row navigate directly to a route?
- Should unmatched/raw flows be visible by default as a secondary tab, or hidden
  behind a filter until requested?
- Which existing hostname/rDNS source is authoritative for endpoint labels when
  device inventory, DNS cache, and flow enrichment disagree?
