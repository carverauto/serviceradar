---
id: threat-investigation
title: Threat Investigation
sidebar_label: Threat Investigation
---

# Threat Investigation

Use this page when you need to answer "which indicator matched which endpoint?"
from the dashboard, SRQL, or `/security/threat-intel`.

Imported OTX indicators are inventory. A current cache row is a live match.
Retrohunt findings are historical evidence. None of those are canonical
security findings.

CVE/CPE catalog and matcher queries (`in:cves`, `in:cve_matches`,
`in:devices cve:`) are documented in the [SRQL Cookbook](./srql-cookbook.md)
and [Endpoint Software Security](./endpoint-software-security.md).

## Which query to run

| Question | Query or route |
|----------|----------------|
| Current matched endpoints | `/security/threat-intel` |
| Current matches in SRQL | `in:threat_intel_matches source:alienvault_otx` |
| Flows for a live match | `in:flows threat_matched:true time:last_24h` |
| Flows for one indicator | `in:flows threat_indicator:"198.51.100.0/24" time:last_24h` |
| Attributed threat flows | `in:attributed_flows threat_source:alienvault_otx time:last_24h` |
| Feed configuration | **Settings → Networks → Threat Intel** |

Dashboard **Matched IPs** is distinct live cache endpoints.
**Indicator matches** is endpoint-to-indicator memberships, not flow
occurrences.

## Current matches versus inventory

`in:threat_intel_matches` joins live `ip_threat_intel_cache` rows to active
indicator CIDRs. Expired cache or indicator rows are excluded unless you
ask for `stale:true`. Provider pulse context is omitted unless an unambiguous
source-object relationship exists.

Interactive threat-aware flow queries require a bounded time window and
default to `last_24h`. Longer searches belong on the retrohunt job, not a
synchronous browser query.

Requires `observability.netflow.view`. Feed mutations stay behind
`plugins.assign`.
