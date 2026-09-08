# Design: SNMP Credential Resolution

## Credential Sources
1. **Per-device override** (device-scoped SNMP credential)
2. **Profile credentials** (resolved via SRQL targeting + priority)
3. **No credentials** (SNMP disabled for that target/device)

## Profile Resolution
- Profiles are matched to devices using `target_query` SRQL.
- If multiple profiles match, the highest `priority` wins.
- If no profile matches, fall back to the default profile when present.

## Discovery + Polling
- Mapper discovery and SNMP polling both use the same credential resolution path.
- Discovery jobs no longer persist SNMP credentials; they rely on profile resolution and device overrides.

## Migration Strategy
- Existing mapper job SNMP credentials need to be migrated to either:
  - A designated SNMP profile with matching SRQL, or
  - Per-device overrides for the affected devices.
