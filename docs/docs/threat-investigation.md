---
id: threat-investigation
title: Threat Investigation
sidebar_label: Threat Investigation
---

# Threat Investigation

Use this page when you need to answer "is this CVE, CPE, or KEV entry on our
fleet?" from SRQL. The Software tab on a device still shows matches for that
host. SRQL is the fleet query.

This page covers **vulnerability catalog and matcher** queries. IP/CIDR IOC
investigation (`in:threat_intel_matches`, threat-aware `in:flows`) is a
follow-on; do not treat imported OTX indicators as local sightings until that
surface ships. Settings for OTX remain at **Settings -> Networks -> Threat Intel**.

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
