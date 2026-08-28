# Draft matrix: `in:flows` filter capabilities

**As of `origin/staging` at `99ddf282c5a5`.**
Sources: catalog `filter_fields`, Rust row/stats/downsample match arms.

Legend:

| Symbol | Meaning |
|--------|---------|
| yes | Supported |
| no | Not supported (engine rejects) |
| hidden | Engine-supported but intentionally not advertised by the builder |
| alias | Alias of another field |

## Modes

| Mode | Trigger tokens | Engine entry |
|------|----------------|--------------|
| **row** | default table / explorer | `flows/filters.rs` |
| **stats** | `stats:...` | `flows/stats/filters.rs` |
| **downsample** | `bucket:...` (+ usually `agg:` / `value_field:` / `series:`) | `downsample/filters.rs` |

Builder UI chart knobs set **downsample**.

The visual builder in this change composes only row and downsample modes. Stats remains an engine/freeform path and is inventoried here for context.

## Field matrix (canonical names; aliases noted)

| Field (catalog / product) | row | stats | downsample | Notes |
|---------------------------|-----|-------|------------|-------|
| `src_endpoint_ip` / `src_ip` | yes | yes | yes | |
| `dst_endpoint_ip` / `dst_ip` | yes | yes | yes | |
| `ip` / `endpoint_ip` | yes | yes | yes | Bidirectional either endpoint |
| `device_addr` / `device_address` | yes | yes | yes | Internal address-list scope used by device traffic-profile queries; engine-supported but intentionally not builder-advertised |
| `src_endpoint_port` / `src_port` | yes | yes | yes | |
| `dst_endpoint_port` / `dst_port` | yes | yes | yes | |
| `port` / `endpoint_port` | yes | yes | no | Row builder only; downsample rejects it |
| `protocol_name` | yes | yes | yes | |
| `protocol_num` / `proto` | yes | yes | yes | |
| `protocol_group` / `proto_group` | yes | yes | yes | |
| `app` | yes | yes | yes | Common `series:` value |
| `direction` | yes | yes | yes | |
| `sampler_address` | yes | yes | yes | |
| `exporter_name` | yes | yes | yes | Advertised in both row and downsample builder lists |
| `in_if_name` / `out_if_name` | yes | yes | yes | Interface names |
| `input_snmp` / `in_if_index` | yes | yes | yes | |
| `output_snmp` / `out_if_index` | yes | yes | yes | |
| `in_if_speed_bps` / `out_if_speed_bps` | yes | yes | yes | |
| `src_cidr` | yes | yes | yes | Supported by the current downsample engine |
| `dst_cidr` | yes | yes | yes | Supported by the current downsample engine |
| `cidr` | yes | yes | yes | Bidirectional; supported by the current downsample engine |
| `src_country_iso2` / `src_country` | yes | yes | no | Geo - row/stats only |
| `dst_country_iso2` / `dst_country` | yes | yes | no | Geo - row/stats only |
| `tag` / `src_tag` / `dst_tag` | yes | yes | no | Prefix tags - row/stats only |
| `near` / `src_near` / `dst_near` | yes | yes | no | Geo proximity - row/stats only |
| `as_path` | no | no | no | Removed from the builder catalog until an engine path supports it |
| `bgp_communities` | no | no | no | Removed from the builder catalog until an engine path supports it |
| `device_id` | yes | yes | no | Row/stats device scope; advertised by the row builder, rejected by flows downsample |
| process / k8s attribution fields | yes (many) | yes (many) | no | Mostly attribution path; not in flows builder list |

## Catalog vs engine (builder pain points)

### In catalog `filter_fields` but **unsafe in chart (downsample) mode**

These row-catalog fields must remain excluded from the downsample selector:

| Field | Risk |
|-------|------|
| `port` / `endpoint_port` | Rejected by downsample |
| `src_country_iso2`, `dst_country_iso2` | Rejected by downsample |
| `tag`, `src_tag`, `dst_tag` | Rejected by downsample |
| `near`, `src_near`, `dst_near` | Rejected by downsample |

### In engine downsample but **missing or incomplete in catalog**

| Field | Note |
|-------|------|
| `device_addr` / `device_address` | Downsample supports these; intentionally omitted from manual builder choices because device-specific query code supplies the address list |

### Proposed v1 `filter_fields_downsample` for flows

Start from engine downsample allowlist (aliases collapsed to preferred catalog names):

```text
src_endpoint_ip, src_ip, dst_endpoint_ip, dst_ip, ip, endpoint_ip,
src_cidr, dst_cidr, cidr,
src_endpoint_port, src_port, dst_endpoint_port, dst_port,
protocol_name, protocol_num, protocol_group, app, direction,
sampler_address, exporter_name,
input_snmp, in_if_index, output_snmp, out_if_index,
in_if_name, out_if_name, in_if_speed_bps, out_if_speed_bps
```

**Explicitly excluded until engine supports them on downsample:**
`port`, `tag*`, `near*`, geo countries, `as_path`, `bgp_communities`.

`device_addr` / `device_address` are deliberately omitted even though the engine accepts them. The manual builder allowlist is a verified subset of engine support, not an exhaustive engine inventory.

Optional product follow-ups (separate engine PRs):

1. Downsample `port:` bidirectional (parity with row)
2. Downsample flows prefix-tag filters if charts need them
3. BGP fields (`as_path`, `bgp_communities`): implement engine filters before restoring builder choices

## Other entities (Phase 0 stubs)

Inventory next (same three-mode table; fill in later PRs):

- [ ] `devices` - mostly row; no downsample
- [ ] `attributed_flows` - row/stats-like; `downsample: false` in catalog
- [ ] `events`, `logs`, `otel_*`
- [ ] Metric entities with `downsample: true` (sysmon-style)

## How to refresh this matrix

1. Diff Rust match arms in:
   - `rust/srql/src/query/flows/filters.rs`
   - `rust/srql/src/query/flows/stats/filters.rs`
   - `rust/srql/src/query/downsample/filters.rs`
2. Diff `Catalog.entity("flows").filter_fields`
3. Update this file in the same PR that changes engine or catalog
