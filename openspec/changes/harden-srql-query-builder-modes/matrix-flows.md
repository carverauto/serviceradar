# Draft matrix: `in:flows` filter capabilities

**As of staging @ cidr-downsample merge (#4859).**  
Sources: catalog `filter_fields`, Rust row/stats/downsample match arms.

Legend:

| Symbol | Meaning |
|--------|---------|
| ✅ | Supported |
| ❌ | Not supported (engine rejects) |
| ⚠ | In catalog but illegal for this mode (builder will emit broken queries today) |
| ≈ | Alias of another field |

## Modes

| Mode | Trigger tokens | Engine entry |
|------|----------------|--------------|
| **row** | default table / explorer | `flows/filters.rs` |
| **stats** | `stats:…` | `flows/stats/filters.rs` |
| **downsample** | `bucket:…` (+ usually `agg:` / `value_field:` / `series:`) | `downsample/filters.rs` |

Builder UI chart knobs set **downsample**.

## Field matrix (canonical names; aliases noted)

| Field (catalog / product) | row | stats | downsample | Notes |
|---------------------------|-----|-------|------------|-------|
| `src_endpoint_ip` / `src_ip` | ✅ | ✅ | ✅ | |
| `dst_endpoint_ip` / `dst_ip` | ✅ | ✅ | ✅ | |
| `ip` / `endpoint_ip` | ✅ | ✅ | ✅ | Bidirectional either endpoint |
| `src_endpoint_port` / `src_port` | ✅ | ✅ | ✅ | |
| `dst_endpoint_port` / `dst_port` | ✅ | ✅ | ✅ | |
| `port` / `endpoint_port` | ✅ | ✅ | ❌ ⚠ | Catalog offers it; **downsample still rejects** |
| `protocol_name` | ✅ | ✅ | ✅ | |
| `protocol_num` / `proto` | ✅ | ✅ | ✅ | |
| `protocol_group` / `proto_group` | ✅ | ✅ | ✅ | |
| `app` | ✅ | ✅ | ✅ | Common `series:` value |
| `direction` | ✅ | ✅ | ✅ | |
| `sampler_address` | ✅ | ✅ | ✅ | |
| `exporter_name` | ✅ | ✅ | ✅ | Not always in catalog filter list |
| `in_if_name` / `out_if_name` | ✅ | ✅ | ✅ | Interface names |
| `input_snmp` / `in_if_index` | ✅ | ✅ | ✅ | |
| `output_snmp` / `out_if_index` | ✅ | ✅ | ✅ | |
| `in_if_speed_bps` / `out_if_speed_bps` | ✅ | ✅ | ✅ | |
| `src_cidr` | ✅ | ✅ | ✅ | After #4859 on downsample |
| `dst_cidr` | ✅ | ✅ | ✅ | After #4859 |
| `cidr` | ✅ | ✅ | ✅ | Bidirectional; after #4859 on downsample |
| `src_country_iso2` / `src_country` | ✅ | ✅ | ❌ ⚠ | Geo — row/stats only |
| `dst_country_iso2` / `dst_country` | ✅ | ✅ | ❌ ⚠ | Geo — row/stats only |
| `tag` / `src_tag` / `dst_tag` | ✅ | ✅ | ❌ ⚠ | Prefix tags — **not** on downsample |
| `near` / `src_near` / `dst_near` | ✅ | ✅ | ❌ ⚠ | Geo proximity — **not** on downsample |
| `as_path` | ❌ ⚠ | ❌ | ❌ ⚠ | In catalog `array_fields`; **no engine match arm found** |
| `bgp_communities` | ❌ ⚠ | ❌ | ❌ ⚠ | In catalog `array_fields`; **no engine match arm found** |
| `device_id` | ✅ | ✅ | ❌ | Scope filter; not in builder catalog list |
| process / k8s attribution fields | ✅ row (many) | ✅ stats (many) | ❌ | Mostly attribution path; not in flows builder list |

## Catalog vs engine (builder pain points)

### In catalog `filter_fields` but **unsafe in chart (downsample) mode**

These are the fields the builder can currently attach while `bucket:` is set, producing engine errors (unless fixed later):

| Field | Risk |
|-------|------|
| `port` / `endpoint_port` | ❌ downsample |
| `src_country_iso2`, `dst_country_iso2` | ❌ downsample |
| `tag`, `src_tag`, `dst_tag` | ❌ downsample |
| `near`, `src_near`, `dst_near` | ❌ downsample |
| `as_path`, `bgp_communities` | ❌ all modes (catalog-only; no engine arms) |

### In engine downsample but **missing or incomplete in catalog**

| Field | Note |
|-------|------|
| `exporter_name` | Downsample ✅; may be underrepresented in builder |
| `input_snmp` / `output_snmp` / if speeds | Downsample ✅; not all in catalog filter_fields |
| `ip` / `cidr` / `port` | Catalog has ip/cidr/port; port still missing on downsample |

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

Optional product follow-ups (separate engine PRs):

1. Downsample `port:` bidirectional (parity with row)  
2. Downsample tag filters if charts need them  
3. BGP fields (`as_path`, `bgp_communities`): implement row filters or remove from catalog (currently catalog-only)

## Other entities (Phase 0 stubs)

Inventory next (same three-mode table; fill in later PRs):

- [ ] `devices` — mostly row; no downsample  
- [ ] `attributed_flows` — row/stats-like; `downsample: false` in catalog  
- [ ] `events`, `logs`, `otel_*`  
- [ ] Metric entities with `downsample: true` (sysmon-style)  

## How to refresh this matrix

1. Diff Rust match arms in:
   - `rust/srql/src/query/flows/filters.rs`
   - `rust/srql/src/query/flows/stats/filters.rs`
   - `rust/srql/src/query/downsample/filters.rs`
2. Diff `Catalog.entity("flows").filter_fields`
3. Update this file in the same PR that changes engine or catalog
