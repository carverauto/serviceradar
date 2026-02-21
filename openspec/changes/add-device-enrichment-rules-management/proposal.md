# Change: Add Device Enrichment Rules Management

## Why
Device vendor/type enrichment is currently embedded in code, making behavior hard to tune for real-world SNMP variability (especially Ubiquiti) and hard to correct quickly in customer environments. Operators need a deterministic, auditable, and user-editable way to control enrichment behavior without rebuilding images.

## What Changes
- Add filesystem-backed device enrichment rule loading from `/var/lib/serviceradar/rules/device-enrichment/*.yaml` with built-in defaults and deterministic merge/precedence.
- Define a typed YAML rule schema for matching SNMP/mapper-derived fields (e.g., `sys_object_id`, `sys_descr`, `sys_name`, `ip_forwarding`, `if_type`/role signals).
- Apply rules during identity/inventory ingestion to set `vendor_name`, `model`, `type`, and `type_id` plus enrichment metadata (`classification_source`, `classification_rule_id`, `classification_confidence`, `classification_reason`).
- Add Settings UI for viewing, creating, editing, validating, and ordering enrichment rules, with import/export and effective rule preview.
- Add explicit fallback behavior when user rules are invalid/unavailable (continue using built-in default rules).
- Add deployment guidance for Docker Compose and Helm mounts for rule overrides.

## Impact
- Affected specs:
  - `device-identity-reconciliation`
  - `device-inventory`
  - `build-web-ui`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/inventory/sync_ingestor.ex`
  - new enrichment rule loader/validator modules under `elixir/serviceradar_core/lib/serviceradar/inventory/`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/**` (new Settings UI surface)
  - deployment docs/values for filesystem mounts
