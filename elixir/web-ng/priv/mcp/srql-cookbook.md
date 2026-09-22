# SRQL cookbook (for MCP agents)

Copy-paste recipes. Replace hostnames, IPs, uids, and time windows. Grammar:
`serviceradar://srql/grammar`. Entity fields: `get_srql_catalog` with `entity`.

There is no cross-field `OR`. Do not write `(src_ip:x OR dst_ip:x)`.

## Devices

```
in:devices sort:last_seen:desc limit:25
in:devices first_seen:last_30d sort:first_seen:desc limit:200
in:devices hostname:%edge%
in:devices ip:10.20.0.0/16
in:devices vendor_name:Cisco sort:hostname:asc
in:devices vendor_name:"Axis Communications"
in:devices is_available:false sort:last_seen:desc
in:devices discovery_sources:(armis)
in:devices metadata.integration_type:armis metadata.query_label:managed
in:devices stats:count() as total by type
in:devices stats:count() as total by vendor_name sort:total:desc
in:devices stats:count() as total by tags.gate limit:100
```

`time:` on devices still means last-seen. Newly added devices use `first_seen:`.

## Identity reconciliation diagnostics

Explaining an inventory change: which devices are tombstoned, what merged into
what, whether an identifier is still real, and what a scheduled reconciliation
run actually did.

Prefer the task tools `trace_device_identity` and `explain_identity_reconciliation`
over composing these by hand; the recipes below are for the cases they do not
cover.

```
in:devices deleted:true sort:last_seen:desc limit:50
in:devices deleted:true hostname:%farm% limit:25
in:merge_audit device_id:sr:<uuid> sort:created_at:desc limit:25
in:merge_audit chain:sr:<uuid> limit:50
in:merge_audit reason:duplicate_mac time:last_7d limit:50
in:device_revival_audit device_uid:sr:<uuid> limit:25
in:revivals time:last_24h sort:revived_at:desc limit:50
in:device_identifiers device_id:sr:<uuid> limit:100
in:device_identifiers identifier_type:mac value:001122334455 limit:25
in:device_identifiers device_id:sr:<uuid> matches_current_facts:false limit:50
in:identity_evidence_edges device:sr:<uuid> limit:100
in:identity_reconciliation_runs time:last_24h limit:25
in:identity_reconciliation_runs merge_cap_reached:true time:last_7d limit:25
in:dire_runs status:failed time:last_7d limit:25
```

`in:devices deleted:true` returns tombstoned devices with `deleted_at`,
`deleted_by`, and `deleted_reason`. Plain `in:devices` hides them.

`chain:` walks the merge graph in BOTH directions from one uid: `direction` is
`merged_into` (where this device went) or `merged_from` (what came into it), and
`depth` is hops from the seed. If `truncated` is true the chain hit its depth cap
and there is more; raise it with `depth:64`.

`matches_current_facts` on `in:device_identifiers` is the difference between an
identifier the owning device still reports and one that is only history. A merge
justified by a MAC whose `matches_current_facts` is false was justified by an old
fact.

`in:identity_evidence_edges` requires a `device:` seed and will refuse an
unseeded query -- it is a self-join across millions of identifier rows. `direct`
means the edge touches the seed; `direct:false` at `depth` 2 or more is
transitive connectivity, which is why the scheduled sweep refuses to merge
components larger than a pair. `cross_partition` flags an edge whose two devices
disagree on partition.

On a run that reports `merge_cap_reached:true`, the sweep stopped at its
configured `max_merges_configured` and more mergeable duplicates may remain for
the next run. `blocked_component_devices` lists the device uids of each component
it declined to merge; seed `in:identity_evidence_edges device:` with one of them
to see why.

## Sweep diagnostics

Declared sweep configuration plus its execution/result history. Requires
`networks.sweeps.view`. `in:sweep_results` is pruned at a 7-day retention
default -- an empty result on an older window means "outside the retention
window", not "no sweep activity"; query `in:sweep_coverage` for the daily
rollup, which survives much longer.

```
in:sweep_groups partition:default enabled:true
in:sweep_profiles name:%rids%
in:sweep_results device_id:<device-uid> time:last_24h sort:inserted_at:desc
in:sweep_results time:last_7d
in:sweep_coverage device_uid:<device-uid> time:last_90d sort:day:desc
in:sweep_executions sweep_group_id:<uuid> sort:started_at:desc
in:device_sweep_overlap device_uid:<device-uid>
in:device_sweep_overlap relationship:declared_not_observed
in:device_sweep_overlap device_uid:<device-uid> relationship:declared_and_observed
```

- `in:sweep_groups partition:default enabled:true` -- which sweep groups are
  enabled in a given partition, and what they are configured to scan.
- `in:sweep_profiles name:%rids%` -- find a scan profile (ports, timing,
  banner-grab settings) by name. Profiles flagged `admin_only` are excluded
  from this entity for every role, and `admin_only` is not an accepted filter
  field -- a profile absent here may still exist and be in use, so treat it as
  "restricted", not "no such profile".
- `in:sweep_results device_id:<device-uid> time:last_24h sort:inserted_at:desc`
  -- what did the last 24h of sweeps find for one device (open ports,
  reachability, per-host errors)?
- `in:sweep_results time:last_7d` -- every per-host sweep result within the
  retention window, across all devices.
- `in:sweep_coverage device_uid:<device-uid> time:last_90d sort:day:desc` --
  the daily coverage rollup for one device beyond the 7-day result window: how
  often it was scanned and available, day by day.
- `in:sweep_executions sweep_group_id:<uuid> sort:started_at:desc` -- the run
  history of one sweep group: status, duration, and host counts per run.
- `in:device_sweep_overlap device_uid:<device-uid>` -- where do sweep groups
  overlap on one device, and which of them are only claiming to sweep it? One
  row per (sweep group, agent) pairing, each labelled by `relationship`:
  `declared_and_observed` (the group targets the device and has produced
  coverage), `declared_not_observed` (the group's compiled target set names the
  device but no coverage row has ever come back for it) and
  `observed_not_declared` (coverage exists from a group whose current
  declaration no longer covers the device). More than one
  `declared_and_observed` row means several groups are sweeping the same
  device, which is how one group's result comes to overwrite another's.
- `in:device_sweep_overlap relationship:declared_not_observed` -- the fleet-wide
  alert list: every declaration that has produced nothing. This is the query
  that proves or kills "the group is configured for TCP but the device only
  reports ICMP". Results already lead with these rows without a `sort:` token,
  so add one only when you want a different order -- an explicit `sort:`
  replaces the alert-first default.
- Two things this entity deliberately refuses rather than silently mishandles: a
  time window (`time:last_24h`) is rejected, because the alert rows have no
  `last_seen_at` to bind a window to and applying one would delete exactly the
  rows you came for; and `admin_only` scanner profile identity is masked in the
  projection, so a NULL `scanner_profile_name`/`profile_id` means "restricted",
  not "the group has no profile" -- the row itself is never dropped, because the
  alert is the operator's business either way.

## Events and logs

```
in:events time:last_24h sort:time:desc limit:50
in:events time:last_24h severity_id:>3 sort:time:desc
in:events device_id:<device-uid> time:last_7d sort:time:desc
in:events message:%authentication% time:last_24h
in:logs service_name:serviceradar-core severity_text:error time:last_1h
in:logs severity_text:(error,warn) time:last_6h sort:timestamp:desc
in:logs body:%timeout% time:last_24h
in:logs trace_id:<trace-id> sort:timestamp:asc
in:logs time:last_24h stats:count() as total by severity_text
```

## NetFlow

```
in:flows time:last_1h stats:sum(bytes_total) as bytes by src_ip sort:bytes:desc limit:10
in:flows ip:8.8.8.8 time:last_24h sort:bytes_total:desc
in:flows cidr:203.0.113.0/24 time:last_24h stats:sum(bytes_total) as bytes by app
in:flows dst_ip:8.8.8.8 time:last_24h sort:bytes_total:desc
in:flows bytes_total:>10000000 time:last_1h sort:bytes_total:desc
in:flows dst_port:(443,8443) time:last_1h
in:flows time:last_24h port:22 sort:time:desc limit:50
in:flows src_cidr:10.0.0.0/8 time:last_1h sort:bytes_total:desc
in:flows tag:site:austin time:last_1h
in:flows time:last_1h stats:sum(bytes_total) as bytes by app sort:bytes:desc
in:flows time:last_6h bucket:5m agg:sum value_field:bytes_total
```

## Threat intel

```
in:threat_intel_matches source:alienvault_otx sort:evaluated_at:desc limit:100
in:threat_intel_matches observed_ip:198.51.100.10
in:flows threat_matched:true time:last_24h sort:time:desc limit:100
in:flows threat_indicator:"198.51.100.0/24" time:last_24h sort:time:desc limit:100
in:attributed_flows threat_source:alienvault_otx time:last_24h sort:time:desc limit:100
```

Current matches are cache memberships, not flow counts. Threat-aware `in:flows`
defaults to `time:last_24h` when `time:` is omitted.

`ip:` / `port:` / `cidr:` / `tag:` match **either** endpoint. Directional forms
are `src_*` / `dst_*`. `port:22` is “SSH either direction”.

## Attributed flows and public endpoints

```
in:public_endpoints port:22 limit:50
in:public_endpoints ip:198.51.100.10
in:public_endpoints exposure_class:Gateway sort:ip:asc limit:50
in:attributed_flows time:last_24h ip:198.51.100.10 sort:time:desc limit:50
in:attributed_flows time:last_24h service_name:gitsrv-http sort:time:desc limit:50
in:attributed_flows time:last_24h port:22 sort:time:desc limit:50
in:attributed_flows time:last_1h process:gitea sort:time:desc limit:50
```

`in:attributed_flows port:22` can be empty while `in:flows port:22` is busy —
that means netflow saw SSH but process join did not. Not a broken `port:`.

## Composite checks

```
in:composite_results stats:count() as n by check,verdict
in:composite_results check:pci-isolation stats:count() as n by verdict
in:composite_results check:pci-isolation stats:"count() as n by input_key, input_value, input_stale"
```

Only `count()` is supported on composite_results. Do not group on `hostname`.

## BGP (BMP)

```
in:bmp_events time:last_24h sort:time:desc limit:50
in:bmp_events router_ip:10.42.68.85 time:last_24h sort:time:desc
in:bmp_events peer_ip:10.42.68.1 time:last_7d
in:bmp_events peer_asn:64512 time:last_24h
in:bmp_events prefix:%203.0.113.0% time:last_7d sort:time:desc
```

## Metrics and alerts

```
in:devices is_available:false time:last_15m
in:cpu_metrics time:last_15m usage_percent:>90 sort:usage_percent:desc
in:disk_metrics time:last_30m usage_percent:>85 sort:usage_percent:desc
in:memory_metrics time:last_15m usage_percent:>90
in:logs severity_text:error time:last_5m stats:count() as errors
in:events severity_id:>3 time:last_5m stats:count() as critical_events
in:services available:false time:last_10m
in:interfaces device_ip:10.0.0.5 latest:true
in:interfaces oper_status:down latest:true
in:gateways is_healthy:false
in:snmp_metrics device_id:<device-uid> time:last_1h sort:timestamp:desc
in:alerts status:open sort:triggered_at:desc
in:otel_metrics is_slow:true time:last_1h sort:timestamp:desc
in:traces status_code:2 time:last_1h sort:timestamp:desc
```

## Advisories, CPEs, and vulnerability assessments

Catalog and assessment tables, not OCSF occurrence rows.

```
in:cves cve:CVE-2024-1234
in:advisories kev:true cvss_score:>=9.0 sort:cvss_score:desc
in:advisory_coordinates cve:CVE-2024-1234 coordinate_type:cpe
in:advisory_cpes cpe_vendor:nginx cpe_product:nginx
in:cve_matches status:active assessment:confirmed disposition:affected kev:true sort:cvss_score:desc
in:cve_matches cve:CVE-2024-1234
in:cve_matches assessment:candidate
in:cve_matches status:resolved
in:cve_matches stats:count() as audit_rows
in:cve_matches status:active assessment:confirmed disposition:affected stats:count() as exposed
in:devices kev:true
in:endpoint_packages cve:CVE-2024-1234 current:true
```

`in:cves` is the NVD/KEV catalog. `in:cve_matches` is an alias for stable
device/package/CVE assessments. Row browsing includes confirmed, candidate, and
resolved states unless filtered; no active-only predicate is implicit. An
unqualified `stats:count()` counts persisted audit/state rows, not exposures.
Only `status:active assessment:confirmed disposition:affected` rows or counts
are actionable. `in:security_findings cve:` is the OCSF event stream
(occurrences), not the catalog. Installed software CPEs stay on
`in:endpoint_packages cpe:` / `rollup_stats:current_cpe_counts`. Do not use
`in:cpes`. Version-range evaluation is not done in SRQL; query matches for
exposure, coordinates for catalog evidence.

## Placeholders

Replace `<device-uid>`, `<trace-id>`, `<name>` with real values from a previous
`execute_srql` or `get_device` result. Do not leave the angle brackets in the query.
