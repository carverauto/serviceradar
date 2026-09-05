---
id: threat-investigation
title: Threat Investigation
sidebar_label: Threat Investigation
---

# Threat Investigation

Use this page for two related investigations: which threat indicator matched an
endpoint, and whether a CVE, CPE, or KEV entry affects the fleet. These are
different data surfaces and should not be treated as interchangeable evidence.

## Threat indicator matches

Imported OTX indicators are inventory. A current cache row is a live match.
Retrohunt findings are historical evidence. None of those are canonical
security findings.

### Which indicator query to run

| Question | Query or route |
|----------|----------------|
| Current matched endpoints | `/security/threat-intel` |
| Current matches in SRQL | `in:threat_intel_matches source:alienvault_otx` |
| Flows for a live match | `in:flows threat_matched:true time:last_24h` |
| Flows for one indicator | `in:flows threat_indicator:"198.51.100.0/24" time:last_24h` |
| Attributed threat flows | `in:attributed_flows threat_source:alienvault_otx time:last_24h` |
| Feed configuration | **Settings -> Networks -> Threat Intel** |

Dashboard **Matched IPs** is distinct live cache endpoints.
**Indicator matches** is endpoint-to-indicator memberships, not flow
occurrences.

### Current matches versus inventory

`in:threat_intel_matches` joins live `ip_threat_intel_cache` rows to active
indicator CIDRs. Expired cache or indicator rows are excluded unless you ask
for `stale:true`. Provider pulse context is omitted unless an unambiguous
source-object relationship exists.

Interactive threat-aware flow queries require a bounded time window and
default to `last_24h`. Longer searches belong on the retrohunt job, not a
synchronous browser query.

Requires `observability.netflow.view`. Feed mutations stay behind
`plugins.assign`.

## Vulnerability exposure

The Software tab on a device shows applicability assessments for that host.
SRQL provides fleet-wide catalog, installed-software, and assessment views.

### Which vulnerability query to run

| Question | Query |
|----------|-------|
| Devices with this CVE | `in:devices cve:CVE-2024-1234` |
| Devices with any KEV match | `in:devices kev:true` |
| Packages on a host matching a CVE | `in:endpoint_packages cve:CVE-2024-1234 current:true` |
| Hosts that currently have this installed CPE | `in:endpoint_packages cpe:cpe:2.3:a:nginx:nginx:% current:true` |
| Actionable assessments (device + package + CVE) | `in:cve_matches status:active assessment:confirmed disposition:affected kev:true` |
| What NVD/KEV says about a CVE | `in:cves cve:CVE-2024-1234` |
| Which CPEs an advisory applies to | `in:advisory_cpes cve:CVE-2024-1234 coordinate_type:cpe` |

There is no `in:devices cpe:`. Installed CPEs are on packages. There is no
`in:cpes` alias; that would collide with package CPE rollups.

### Four surfaces that look similar

Do not mix these up:

1. **Catalog** - `in:cves` / `in:advisories` / `in:advisory_cpes`. Global NVD
   and KEV data. Default `current:true`. Does not mean the CVE is on your
   network.
2. **Assessment** - `in:endpoint_vulnerability_assessments` (aliases
   `package_vulnerabilities`, `cve_matches`, `vulnerability_matches`,
   `advisory_matches`, and the legacy `endpoint_vulnerability_matches`). One
   stable device/package/CVE decision after generic and distro-aware
   adjudication. All candidate, confirmed, and resolved states are returned
   unless you filter them.
3. **Installed software** - `in:endpoint_packages`. `cpe:` here is array
   overlap on the package's CPE list, not NVD version matching. `cve:` /
   `kev:` are `EXISTS` checks against active, confirmed, affected assessments.
4. **OCSF occurrences** - `in:security_findings cve:`. Event-shaped findings,
   not the advisory catalog and not the matcher table.

SRQL does **not** re-evaluate `versionStartIncluding` / `versionEndExcluding` or
Debian version rules. Ask the catalog for bounds; ask assessments for the
persisted applicability decision.

### Devices by CVE or KEV

```srql
in:devices cve:CVE-2024-1234
in:devices kev:true
```

CVE equality is case-insensitive (`cve:cve-2024-1234` matches). Each device
appears once even if several packages match. Requires `devices.view`.

### Packages by CVE or installed CPE

```srql
in:endpoint_packages cve:CVE-2024-1234 current:true
in:endpoint_packages cpe:cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:* current:true
in:endpoint_packages cpe:cpe:2.3:a:nginx:nginx:% current:true
in:endpoint_packages rollup_stats:current_cpe_counts limit:60
```

Rows include `device_uid`. Wildcards use `%`.

### Assessment decisions and evidence

```srql
in:cve_matches cve:CVE-2024-1234
in:cve_matches status:active assessment:confirmed disposition:affected kev:true cvss_score:>=9.0 sort:cvss_score:desc
in:cve_matches assessment:candidate freshness:stale
in:cve_matches status:resolved
in:cve_matches cpe:cpe:2.3:a:nginx:nginx:%
in:cve_matches stats:count() as audit_rows
in:vulnerability_matches status:active assessment:confirmed disposition:affected kev:true stats:count() as n by severity
```

Rows include the applicability decision, authority, freshness, device, package
name/version, fixed version, CVSS, KEV, and `epss_score` / `due_date` when
present. A `cpe:` filter searches correlated raw-match evidence; an assessment
may instead be supported only by a normalized distro assertion. `time:` filters
`last_seen_at`. Row browsing and an unqualified `stats:count()` include every
lifecycle state; that raw count is the number of persisted audit/state rows,
not current exposures. Exposure rows and counts require all three filters:
`status:active assessment:confirmed disposition:affected`.

### Catalog lookup

```srql
in:cves cve:CVE-2024-1234
in:advisories kev:true cvss_score:>=9.0 sort:cvss_score:desc
in:advisory_cpes cve:CVE-2024-1234 coordinate_type:cpe
in:advisory_cpes cpe_vendor:nginx cpe_product:nginx
```

Catalog rows omit the raw NVD object. Coordinate stats require a selective
filter (CVE, vendor+product, or CPE value). `time:` on advisories is
`published_at`.

### Suggested path

1. Start from a CVE ID, a KEV list, or a product (`cpe_vendor` + `cpe_product`).
2. Confirm the catalog row: `in:cves cve:...`.
3. List applicability CPEs: `in:advisory_cpes cve:...`.
4. List affected hosts with `in:devices cve:...`; use
   `in:cve_matches cve:... status:active assessment:confirmed disposition:affected`
   for package-level actionable rows.
5. Open the device Software tab for package-level evidence.

Copy-paste variants also live in the
[SRQL Cookbook](./srql-cookbook.md#threat-investigation) and the MCP cookbook
(`serviceradar://srql/cookbook`). Entity fields are in the
[SRQL Reference](./srql-language-reference.md#vulnerability_advisories). See
[Endpoint Software Security](./endpoint-software-security.md) for the matching
model.
