# Change: Enable SNMPv3 in poller, discovery, and mapper

GitHub: https://github.com/carverauto/serviceradar/issues/4149

## Why

The UI, SNMP profile forms, device overrides, proto messages, and compiler already
describe SNMPv3 (username, security level, auth/priv protocols and passwords). That
path has never been proven against a real USM device. Farm01 still speaks SNMPv2c.
After this change lands, farm01 will be converted to SNMPv3 so discovery, topology,
and interface polling can be verified on the live cluster.

Today a v3 profile can be saved and compiled, but the mapper discovery engine does
not actually speak USM correctly: it hard-codes `AuthPriv`, never sets the USM
security model, silently ignores unknown protocol names, and drops `security_level`
on the compiler-to-mapper hop. Unified v3 credential secrets also do not encode
`version` or `security_level`, so a v3 secret bound to a still-v2c profile is
treated as a missing community string and skipped.

## What Changes

- Make the embedded SNMP poller and the mapper discovery engine open SNMPv3 USM
  sessions that honor the configured security level (`noAuthNoPriv`, `authNoPriv`,
  `authPriv`) and auth/privacy protocols.
- Carry `security_level` (and implied `version: v3`) through credential resolution,
  SNMP/mapper compilers, agent mapper JSON, and the discovery proto.
- Normalize protocol identifiers so `SHA-256` / `SHA256` / `sha256` (and the AES
  equivalents) all select the same gosnmp algorithm. Reject unknown identifiers
  instead of falling through to no-auth.
- Infer SNMPv3 from a v3 credential secret even when the parent profile record is
  still v2c, so unified credentials are self-describing.
- Add hermetic USM GET/walk tests and a farm01 verification checklist. v1/v2c
  behavior is unchanged.

## Impact

- Affected specs: `snmp-checker`, `network-discovery`
- Affected code:
  - Mapper USM client: `go/pkg/mapper/utils.go`, `go/pkg/mapper/types.go`,
    `go/pkg/mapper/grpc.go`, `go/pkg/agent/mapper_config_gateway.go`
  - Poller USM client: `go/pkg/agent/snmp/client.go`, `go/pkg/agent/snmp/types.go`
  - Discovery proto: `proto/discovery/discovery.proto` (`SNMPCredentials`)
  - Credential compilation: `elixir/serviceradar_core/lib/serviceradar/snmp_profiles/credential_resolver.ex`,
    `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/{snmp,mapper}_compiler.ex`,
    `elixir/serviceradar_core/lib/serviceradar/credentials/native_descriptors.ex`
- Related in-flight change: `refactor-unified-credential-management` owns the
  native SNMP descriptor shape. This change adds the missing v3 fields to that
  descriptor; it does not replace the unified-credential UI work.
- Out of scope: converting farm01 device configs (operator step after merge),
  SNMPv3 context names (see design open questions), SNMP trap ingestion, rewriting
  credential settings UI.
