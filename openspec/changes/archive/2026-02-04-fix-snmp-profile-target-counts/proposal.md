# Change: Fix SNMP Profile Target Counts in Web UI

## Why
SNMP profiles in the web-ng Settings → SNMP view currently render a hardcoded "0 targets" value. The default profile also lacks an explicit target query, while the UI assumes interface targeting, which conflicts with the expected `in:devices` default. This misleads operators and makes it impossible to verify whether SRQL targeting is working.

## What Changes
- Normalize SNMP profile targeting so missing/empty queries default to `in:devices`.
- Compute and display accurate target counts for each SNMP profile in the list view and editor.
- Align SNMP profile target count semantics with SRQL device/interface targeting (interface queries reduce to distinct devices).
- Surface invalid or failed target count evaluations as "Unknown" instead of a misleading zero.

## Impact
- Affected specs: snmp-checker, build-web-ui
- Affected code: `web-ng/lib/serviceradar_web_ng_web/live/settings/snmp_profiles_live/index.ex`, `elixir/serviceradar_core/lib/serviceradar/snmp_profiles/*`
