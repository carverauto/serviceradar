# Change: Remove sysmon is_default flag

## Why
The `is_default` sysmon profile flag is misleading and hides SRQL targeting failures by silently falling back to a default profile. We want sysmon profiles to apply only when their SRQL target queries match devices.

## What Changes
- Remove the `is_default` field and default-profile behavior from sysmon profile management. **BREAKING**
- Sysmon configuration resolution uses only SRQL-targeted profiles or local `sysmon.json` overrides.
- If no sysmon profile matches, the control plane returns a disabled sysmon config and the agent does not collect sysmon metrics.
- Update UI copy/behavior to show unassigned profiles and remove default-specific protections.
- Drop the `is_default` column and any bootstrap/seed logic tied to it.

## Impact
- Affected specs: `agent-configuration`, `build-web-ui`
- Affected code: core sysmon config resolver, sysmon profile bootstrap/seed logic, Ash resources/migrations, web-ng UI, API serializers/tests
