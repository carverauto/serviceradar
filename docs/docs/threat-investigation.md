---
id: threat-investigation
title: Threat Investigation
sidebar_label: Threat Investigation
---

# Threat Investigation

Use this page for two related questions:

- "Is this CVE, CPE, or KEV entry on our fleet?" -- the vulnerability catalog and
  matcher queries below.
- "Which indicator matched which endpoint?" -- the IP/CIDR IOC section at the end.

The Software tab on a device still shows matches for that host. SRQL is the fleet
query. Settings for OTX are at **Settings -> Networks -> Threat Intel**.

## Which query to run

| Question | Query |
|----------|--------|
| Devices with this CVE | `in:devices cve:CVE-2024-1234` |
| Devices with any KEV match | `in:devices kev:true` |
| Packages on a host matching a CVE | `in:endpoint_packages cve:CVE-2024-1234 current:true` |
| Hosts that currently have this installed CPE | `in:endpoint_packages cpe:cpe:2.3:a:nginx:nginx:% current:true` |
| Matcher rows (device + package + CVE) | `in:cve_matches kev:true` |
| What NVD/KEV says about a CVE | `in:cves cve:CVE-2024-1234` |
| Which CPEs an advisory applies to | `in:advisory_cpes cve:CVE-2024-1234 coordinate_type:cpe` |

There is no `in:devices cpe:`. Installed CPEs are on packages. There is no
`in:cpes` alias; that would collide with package CPE rollups.

## Four surfaces that look similar

Do not mix these up:

1. **Catalog** — `in:cves` / `in:advisories` / `in:advisory_cpes`. Global NVD
   and KEV data. Default `current:true`. Does not mean the CVE is on your
   network.
2. **Exposure** — `in:cve_matches` (aliases `vulnerability_matches`,
   `advisory_matches`). Rows the central matcher wrote after CPE/PURL
   version-range evaluation. Default `status:active`. This is "our devices."
3. **Installed software** — `in:endpoint_packages`. `cpe:` here is array
   overlap on the package's CPE list, not NVD version matching. `cve:` /
   `kev:` are EXISTS against active matches.
4. **OCSF occurrences** — `in:security_findings cve:`. Event-shaped findings,
   not the advisory catalog and not the matcher table.

SRQL does **not** re-evaluate `versionStartIncluding` / `versionEndExcluding`.
Ask the catalog for bounds; ask matches for "is this install in range."

## Devices by CVE or KEV

```srql
in:devices cve:CVE-2024-1234
in:devices kev:true
```

CVE equality is case-insensitive (`cve:cve-2024-1234` matches). Each device
appears once even if several packages match. Requires `devices.view`.

## Packages by CVE or installed CPE

```srql
in:endpoint_packages cve:CVE-2024-1234 current:true
in:endpoint_packages cpe:cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:* current:true
in:endpoint_packages cpe:cpe:2.3:a:nginx:nginx:% current:true
in:endpoint_packages rollup_stats:current_cpe_counts limit:60
```

Rows include `device_uid`. Wildcards use `%`.

## Matcher evidence

```srql
in:cve_matches cve:CVE-2024-1234
in:cve_matches kev:true cvss_score:>=9.0 sort:cvss_score:desc
in:cve_matches cpe:cpe:2.3:a:nginx:nginx:%
in:vulnerability_matches kev:true stats:count() as n by severity
```

Rows include device, package name/version, CPE evidence, CVSS, KEV, and
`epss_score` / `due_date` when present on the match. Pass `status:resolved`
for history. `time:` filters `last_seen_at`.

## Catalog lookup

```srql
in:cves cve:CVE-2024-1234
in:advisories kev:true cvss_score:>=9.0 sort:cvss_score:desc
in:advisory_cpes cve:CVE-2024-1234 coordinate_type:cpe
in:advisory_cpes cpe_vendor:nginx cpe_product:nginx
```

Catalog rows omit the raw NVD object. Coordinate stats require a selective
filter (CVE, vendor+product, or CPE value). `time:` on advisories is
`published_at`.

## Suggested path

1. Start from a CVE id, a KEV list, or a product (`cpe_vendor` + `cpe_product`).
2. Confirm the catalog row: `in:cves cve:...`.
3. List applicability CPEs: `in:advisory_cpes cve:...`.
4. List affected hosts: `in:devices cve:...` or `in:cve_matches cve:...`.
5. Open the device Software tab for package-level evidence.

Copy-paste variants also live in the [SRQL Cookbook](./srql-cookbook.md#threat-investigation)
and the MCP cookbook (`serviceradar://srql/cookbook`). Entity fields are in the
[SRQL Reference](./srql-language-reference.md#vulnerability_advisories).
## IP/CIDR indicator matches

Imported OTX indicators are inventory. A current cache row is a live match.
Retrohunt findings are historical evidence. None of those are canonical
security findings.

### Which query to run

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

### Current matches versus inventory

`in:threat_intel_matches` joins live `ip_threat_intel_cache` rows to active
indicator CIDRs. Expired cache or indicator rows are excluded unless you
ask for `stale:true`. Provider pulse context is omitted unless an unambiguous
source-object relationship exists.

Interactive threat-aware flow queries require a bounded time window and
default to `last_24h`. Longer searches belong on the retrohunt job, not a
synchronous browser query.

Requires `observability.netflow.view`. Feed mutations stay behind
`plugins.assign`.
