# Change: Integrate SNMP Checker into Agent

## Why

The SNMP checker currently runs as a standalone service that agents communicate with via gRPC. This adds operational complexity - users must install and configure a separate snmp-checker service alongside the agent. Integrating SNMP monitoring directly into the agent simplifies deployment and enables dynamic configuration through SNMP profiles, just like sysmon.

Reference: https://github.com/carverauto/serviceradar/issues/2222

## What Changes

### Go Agent
- **Embed SNMP checker** into `serviceradar-agent` as `pkg/agent/snmp_service.go`
- **Dynamic config loading**: Agent fetches SNMP configuration from control plane via gRPC
- **Config refresh**: Periodic refresh with hot-reload (same pattern as sysmon)
- **Local override**: Support `/etc/serviceradar/snmp.json` for offline operation

### Elixir Core
- **SNMPProfile resource**: Ash resource with profile settings (targets, OIDs, intervals)
- **SNMPCompiler**: Implements `ServiceRadar.AgentConfig.Compiler` to generate agent SNMP config
- **SRQL targeting**: Profiles target devices via SRQL queries (like sysmon profiles)

### UI (web-ng)
- **SNMP Profiles settings page**: Create/edit/delete SNMP monitoring profiles
- **SRQL query builder**: Target devices using existing SRQL components
- **Profile form**: Configure targets, OID sets, polling intervals, authentication
- **Preview devices**: Show which devices will receive the profile

### Proto
- **AgentConfigResponse extension**: Add `SNMPConfig` message to config response
- **SNMPConfig message**: Targets, OIDs, authentication, intervals

## Impact

- Affected specs: `snmp-checker`, `agent-configuration`
- New specs: None (extends existing)
- Affected code:
  - `pkg/agent/` - New snmp_service.go
  - `pkg/checker/snmp/` - Refactor as embeddable library
  - `elixir/serviceradar_core/lib/serviceradar/snmp_profiles/` - New Ash resources
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/` - SNMP compiler
  - `web-ng/lib/serviceradar_web_ng_web/live/settings/` - SNMP settings page
  - `proto/monitoring.proto` - SNMP config messages
