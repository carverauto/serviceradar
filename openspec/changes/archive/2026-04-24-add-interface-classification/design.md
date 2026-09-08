# Design: Interface Classification Engine

## Overview
Introduce a rule-driven classification pass for discovered interfaces. The engine runs during interface ingestion (mapper results) and assigns one or more classifications such as `management`, `wan`, `lan`, `vpn`, `wireguard`, `loopback`, `virtual`, or `unknown`. Rules are persisted as Ash resources so the UI can manage them later.

## Data Model
### New Ash Resource: InterfaceClassificationRule
- **Attributes**
  - `name` (string, required)
  - `enabled` (boolean, default true)
  - `priority` (integer, higher wins)
  - `vendor_pattern` (string, optional) — matched against device vendor/model/sysDescr
  - `model_pattern` (string, optional)
  - `sys_descr_pattern` (string, optional)
  - `if_name_pattern` (string, optional) — matches `if_name`
  - `if_descr_pattern` (string, optional)
  - `if_alias_pattern` (string, optional)
  - `if_type_ids` (array<int>, optional)
  - `ip_cidr_allow` (array<string>, optional) — only classify if interface IP is within one of these CIDRs
  - `ip_cidr_deny` (array<string>, optional)
  - `classifications` (array<string>, required) — e.g. `["management", "wan"]`
  - `metadata` (map, optional) — extensible outputs for future
- **Actions**
  - `read` (list/get)
  - `create` / `update` / `destroy` (admin/operator only)

### Interface Resource Extension
- Add `classifications` (array<string>, default [])
- Add `classification_meta` (map, default %{})
- Add `classification_source` (string, default "rules")

## Classification Flow
1. During mapper interface ingestion, load enabled rules ordered by priority.
2. Evaluate rules against the interface + device context:
   - interface fields: `if_name`, `if_descr`, `if_alias`, `if_type`, `ip_addresses`, `if_phys_address`
   - device fields: `vendor_name`, `model`, `sys_descr`, `hostname`
3. Aggregate matches:
   - highest priority rules win for mutually exclusive classifications (`management`, `wan`, `loopback`, `vpn`)
   - non-exclusive tags (`wireguard`) can be additive
4. Persist classification fields on the interface record.

## Default Rules (Seed)
- **UniFi/Ubiquiti management**: if_descr matches `Annapurna Labs Ltd. (Gigabit|SFP\+ 10G) Ethernet Adapter` AND `if_oper_status=up` AND device vendor matches `Ubiquiti` ⇒ `management`.
- **WireGuard VPN**: if_name matches `^wg` OR if_descr contains `WireGuard` ⇒ `vpn`, `wireguard`.

## Future UI
Expose rule CRUD in Settings → Networks (new tab or section). Use the persisted rule resource so UI can configure vendor-specific patterns without code changes.
