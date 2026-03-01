# Change: Fix mapper SNMP ping gate skipping reachable devices

## Why

GitHub Issue: #2653

The mapper discovery engine runs an ICMP ping pre-check before SNMP-walking each target. Devices that don't respond to ICMP (common for managed switches, APs, and firewalled hosts) are silently skipped, even when SNMP is fully reachable. This means UniFi-discovered devices that are added to the SNMP target pool never get SNMP-walked, resulting in:

- **Missing interfaces**: A 24-port switch shows 0 interfaces in inventory
- **Missing enrichment**: vendor, model, sysDescr, sysLocation, sysContact are empty
- **Missing topology**: No LLDP/CDP neighbor discovery for these devices
- **No available_metrics**: No per-interface metric probing, so SNMP polling can't collect traffic/error data

Evidence from agent-dusk logs: Phase 1 (UniFi API) discovers 12 devices and adds 13 SNMP targets. Phase 2 (SNMP polling) completes in ~2 seconds for 13 targets — only the 2 seed routers (farm01, tonka01) produce SNMP results. The other 11 devices are skipped by the ping gate.

Manual verification confirms SNMP is reachable: `snmpwalk -v2c -c <community> 192.168.1.131` returns full system info and interface MIBs.

## What Changes

- **Mapper discovery engine (Go)**: Replace the hard ICMP ping gate with a soft pre-check. If ping fails, still attempt SNMP connection. Only skip the target if SNMP connection itself fails. Log a warning when ping fails but SNMP succeeds (to flag potential network issues).
- **Discovery job status**: Ensure the mapper job's `last_run_status` and `last_run_at` are updated when results are ingested, so the UI reflects actual execution.

## Impact

- Affected specs: `network-discovery`
- Affected code:
  - `pkg/mapper/discovery.go` (remove hard ping gate, make ping advisory)
