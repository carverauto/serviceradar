# Change: Improve Threat Intel Investigation

## Why

The operations dashboard reports imported IOCs, matched IPs, and IOC hits, but
activating the Threat Intel panel opens the administrative settings page. The
settings page exposes only small, non-interactive samples, so an operator cannot
answer which indicator matched which endpoint, inspect the supporting flow, or
pivot into attributed traffic. SRQL likewise has no threat-intel match entity or
threat filters for `in:flows` and `in:attributed_flows`.

The current "Max IOCs" controls are also misleading. They limit work within one
collector or worker invocation; they do not cap retained inventory, which is why
the dashboard can correctly show a corpus larger than that value. Completeness
should advance through bounded pages and resumable cursors, not silently skip
valid indicators after an independent count threshold.

## What Changes

- Add an authenticated `/security/threat-intel` investigation workspace that
  separates current endpoint-to-indicator matches, historical retrohunt evidence,
  and imported inventory from feed configuration.
- Make the dashboard Threat Intel summary open the investigation workspace while
  retaining an explicit `Manage` action for
  `/settings/networks/threat-intel`.
- Make matched endpoints and indicators selectable and show the matched value,
  provider/source, label or pulse context when available, severity, confidence,
  evaluation freshness, expiry, evidence time/count, and clear unavailable-state
  labels instead of implying evidence that is not stored.
- Add SRQL `in:threat_intel_matches` for current IP/CIDR matches and add
  `threat_matched`, `threat_source`, `threat_indicator`,
  `threat_observed_ip`, and `threat_severity` filters to both `in:flows` and
  `in:attributed_flows`.
- Add shareable pivots from a threat match to matching NetFlow and attributed-flow
  searches while preserving the selected indicator, endpoint, source, and time
  window in the URL.
- Correct metric labels so `Matched IPs` means distinct cached endpoints and
  `Indicator matches` means endpoint-to-indicator memberships. Do not call the
  latter flow occurrences or findings.
- Remove the independent operator-facing `Max IOCs` / `max_indicators` limit from
  OTX settings and assignment forms. Bound collection with page size, maximum
  pages per invocation, wall time, request-attempt budgets, payload admission,
  and a persisted continuation cursor instead.
- Keep existing assignment and job configurations containing `max_iocs`,
  `max_indicators`, or `otx_max_indicators` backward compatible: accept and ignore
  those legacy values, remove them on the next successful edit, and never reject
  or reset an assignment solely because the obsolete key is present.
- Add index, query-plan, RBAC, redaction, pagination, timeout, and explicit error
  requirements suitable for enterprise retained-flow volumes.

## Minimal First Increment

The first increment is intentionally IP/CIDR focused and uses the existing
`platform.ip_threat_intel_cache`, `platform.threat_intel_indicators`,
`platform.threat_intel_source_objects`, and
`platform.otx_retrohunt_findings` data. It does not create a competing canonical
finding model. It delivers:

1. the `/security/threat-intel` current-match list and detail workflow;
2. `in:threat_intel_matches` plus threat-aware `in:flows` and
   `in:attributed_flows` pivots;
3. corrected dashboard navigation and metric terminology; and
4. removal of the redundant per-invocation IOC cap with resumable collection.

The broader `add-cti-signal-coverage` change remains responsible for canonical
cross-signal sightings/findings and domain, URL, hash, DNS, HTTP/WAF, endpoint,
SBOM, and SIEM matching.

## Non-Goals

- Add DNS, URL, file-hash, package, CVE, TLS fingerprint, or SIEM matching.
- Replace the OTX importer, the existing IP/CIDR cache, or the retained-flow
  storage model.
- Treat every imported IOC as a local sighting or security finding.
- Add automatic blocking, firewall policy, or response actions.
- Redesign the general Security Findings dashboard or the OCSF finding model.
- Expose OTX credentials, raw archived payloads, or unrestricted external links
  in investigation results.

## Dependencies And Overlap

- Builds on `add-alienvault-otx-integration`, which owns OTX ingestion, current
  IP/CIDR matching, source metadata, and retrohunt tables. The modified OTX
  requirement in this change must land after or together with that change.
- Implements a narrow first slice of `add-cti-signal-coverage` tasks 7.1, 7.2,
  8.1, and 8.2 for existing IP/CIDR data only. It does not supersede that change.
- Complements `improve-attributed-flow-investigation` by adding threat filters and
  pivots to its existing attributed-flow surface.
- Refines `update-dashboard-drilldown-actions`: the Threat Intel panel will point
  to the new evidence surface rather than the only previously available settings
  route.
- Does not overlap `complete-security-analytics-pipeline`, which explicitly leaves
  CTI/OTX matching to the threat-intel changes.

## Impact

- Affected specs: `threat-intel-investigation` (new), `build-web-ui`, `srql`,
  `observability-netflow`, `alienvault-otx-threat-intel`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/security_live/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/threat_intel_live/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`
  - `elixir/serviceradar_core/lib/serviceradar/observability/**threat_intel**`
  - `elixir/serviceradar_core/lib/serviceradar/observability/netflow_security_refresh_worker.ex`
  - `elixir/serviceradar_core/priv/repo/migrations/**` only if an additional
    supporting index is proven necessary
  - `rust/srql/src/parser/**`, `rust/srql/src/query/**`, `rust/srql/src/models/**`,
    and `rust/srql/src/schema.rs`
  - `go/cmd/wasm-plugins/alienvault-otx/**`
