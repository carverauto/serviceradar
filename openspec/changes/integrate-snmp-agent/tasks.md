## 1. Proto Definitions

- [x] 1.1 Add SNMPConfig message to `proto/monitoring.proto`
- [x] 1.2 Add SNMPTargetConfig, SNMPv3Auth, OIDConfig messages
- [x] 1.3 Add enums: SNMPVersion, SNMPSecurityLevel, SNMPAuthProtocol, SNMPPrivProtocol, OIDDataType
- [x] 1.4 Add SNMPConfig field to AgentConfigResponse
- [x] 1.5 Generate Go and Elixir protobuf code

## 2. Elixir Resources (serviceradar_core)

- [x] 2.1 Create SNMPProfile resource at `lib/serviceradar/snmp_profiles/snmp_profile.ex`
- [x] 2.2 Create SNMPTarget resource at `lib/serviceradar/snmp_profiles/snmp_target.ex`
- [x] 2.3 Create SNMPOIDConfig resource at `lib/serviceradar/snmp_profiles/snmp_oid_config.ex`
- [x] 2.4 Create SNMPOIDTemplate resource at `lib/serviceradar/snmp_profiles/snmp_oid_template.ex`
- [x] 2.5 Create SNMPProfiles domain at `lib/serviceradar/snmp_profiles.ex`
- [x] 2.6 Add SRQL target_query and priority fields to SNMPProfile
- [x] 2.7 Add credential encryption for community strings and SNMPv3 passwords (Cloak)
- [ ] 2.8 Generate Ash migrations with `mix ash.codegen add_snmp_profiles`
- [x] 2.9 Add tenant isolation (belongs_to Tenant, policies)

## 3. SNMP Config Compiler

- [x] 3.1 Create SNMPCompiler at `lib/serviceradar/agent_config/compilers/snmp_compiler.ex`
- [x] 3.2 Implement `Compiler` behaviour callbacks (config_type, compile, source_resources)
- [x] 3.3 Create SRQLTargetResolver for SNMP (similar to sysmon)
- [x] 3.4 Profile resolution: SRQL match → default profile fallback
- [x] 3.5 Register compiler in AgentConfig.Compiler
- [x] 3.6 Add proto encoding for SNMPConfig (via compile output)
- [x] 3.7 Write compiler tests

## 4. Go Agent SNMP Service

- [x] 4.1 Create `pkg/agent/snmp_service.go` with SNMPAgentService struct
- [x] 4.2 Implement Start/Stop/Status interface
- [x] 4.3 Config refresh loop (same pattern as sysmon_service.go)
- [x] 4.4 Parse SNMPConfig from proto via ApplyProtoConfig
- [x] 4.5 Create/update/remove SNMPCollectors based on config
- [x] 4.6 Local config override support (`/etc/serviceradar/snmp.json`)
- [x] 4.7 Config caching for offline operation
- [x] 4.8 Health check status aggregation from collectors
- [x] 4.9 Write unit tests

## 5. Refactor SNMP Checker as Library

- [x] 5.1 Add DefaultConfig() and LoadConfigFromFile() to snmp package
- [x] 5.2 Add ValidateForAgent() for less strict validation
- [x] 5.3 Add NewSNMPServiceForAgent() factory function
- [x] 5.4 Add Enabled field to SNMPConfig
- [x] 5.5 Context cancellation handled via existing service
- [x] 5.6 Thread-safety handled via existing service
- [ ] 5.7 Update existing snmp_checker.go to use refactored collector
- [ ] 5.8 Write/update collector unit tests

## 6. Agent Integration

- [x] 6.1 Add snmpService field to Server struct
- [x] 6.2 Add initSNMPService method
- [x] 6.3 Initialize SNMPService on agent startup (if enabled)
- [x] 6.4 Add GetSNMPStatus method
- [x] 6.5 SNMP config refresh handled by SNMPAgentService
- [ ] 6.6 Write integration tests

## 7. UI - SNMP Profiles Page (Modal-Driven)

- [x] 7.1 Create `lib/serviceradar_web_ng_web/live/settings/snmp_profiles_live/index.ex`
- [x] 7.2 Profile list table (name, enabled, targets count, matched interfaces)
- [x] 7.3 Profile form with basic settings (poll interval, timeout, retries)
- [x] 7.4 SRQL query builder integration for interface targeting
- [ ] 7.5 Matched interfaces preview panel (count function)
- [x] 7.6 Add SNMP profiles to settings navigation sidebar

## 8. UI - SNMP Target Modal

- [x] 8.1 Target modal component (nested from profile modal)
- [x] 8.2 Connection tab: host, port, SNMP version selector
- [x] 8.3 Auth tab (v1/v2c): community string with show/hide toggle
- [x] 8.4 Auth tab (v3): username, security level, protocol selectors, passwords
- [ ] 8.5 OIDs tab: template selector button + custom OID list
- [ ] 8.6 Add/remove OID rows with data type, scale, delta options
- [ ] 8.7 Test connection button with result feedback

## 9. OID Templates (Vendor-Based Library)

- [x] 9.1 Create built-in templates module at `lib/serviceradar/snmp_profiles/builtin_templates.ex`
- [x] 9.2 Define Standard (MIB-II) templates:
  - [x] 9.2.1 interface-stats: ifInOctets, ifOutOctets, ifOperStatus, ifSpeed, ifAdminStatus
  - [x] 9.2.2 system-info: sysDescr, sysUpTime, sysName, sysLocation, sysContact
  - [x] 9.2.3 ip-stats: ipInReceives, ipOutRequests, ipInDiscards, ipForwDatagrams
- [x] 9.3 Define Cisco templates:
  - [x] 9.3.1 cpu-memory: cpmCPUTotal5sec, cpmCPUTotal1min, ciscoMemoryPoolUsed/Free
  - [x] 9.3.2 environment: ciscoEnvMonTemperatureValue, ciscoEnvMonFanState
  - [x] 9.3.3 bgp: cbgpPeerState, cbgpPeerPrefixAccepted, cbgpPeerPrefixDenied
- [x] 9.4 Define Juniper templates:
  - [x] 9.4.1 cpu-memory: jnxOperatingCPU, jnxOperatingBuffer, jnxOperatingMemory
  - [x] 9.4.2 environment: jnxOperatingTemp, jnxOperatingState
- [x] 9.5 Define Arista templates:
  - [x] 9.5.1 environment: aristaEnvMonTempValue, aristaEnvMonFanState
- [x] 9.6 Create SNMPOIDTemplate resource for user-created templates
- [ ] 9.7 UI: Template browser modal (vendor tabs, search, preview)
- [ ] 9.8 UI: "Copy to Custom" action for built-in templates
- [ ] 9.9 UI: Create/edit custom template modal

## 10. Testing

- [x] 10.1 Elixir: SNMPProfile resource tests
- [x] 10.2 Elixir: SNMPCompiler unit tests
- [ ] 10.3 Elixir: SRQL targeting resolution tests
- [x] 10.4 Go: SNMPService unit tests
- [x] 10.5 Go: Config refresh and hot-reload tests
- [x] 10.6 Go: Collector lifecycle tests
- [ ] 10.7 Integration: Agent receives SNMP config from control plane
- [ ] 10.8 E2E: Create profile in UI → agent polls SNMP target

## 11. Documentation

- [ ] 11.1 Update agent configuration docs for embedded SNMP
- [ ] 11.2 Document SNMP profile targeting with SRQL
- [ ] 11.3 Migration guide from standalone snmp-checker
- [ ] 11.4 OID template reference

## 12. Backwards Compatibility

- [ ] 12.1 Ensure standalone snmp-checker still works
- [ ] 12.2 Agent gracefully ignores SNMP config if standalone checker configured
- [ ] 12.3 Add deprecation warning to standalone snmp-checker
