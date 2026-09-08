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
on the compiler-to-mapper hop. SNMP's native descriptor sets `supports_rules: false`,
so the only UI path is a standalone encrypted secret bound onto the SNMP profile
(`credential_secret_id`). That is the wrong object: device and integration
credentials are **credential rules** in CNPG, not Kubernetes/Vault secrets and not
profile-attached secret UUIDs. Farm01 currently has a profile-bound `snmp-v3`
secret and no SNMP credential rule.

## What Changes

- Make the embedded SNMP poller and the mapper discovery engine open SNMPv3 USM
  sessions that honor the configured security level (`noAuthNoPriv`, `authNoPriv`,
  `authPriv`) and auth/privacy protocols.
- Resolve SNMP credentials from `network_credential_rules` (provider `snmp`,
  purpose `snmp_monitoring`). Set the native SNMP descriptor `supports_rules: true`
  and stop treating a profile `credential_secret_id` as the product path.
- Carry `security_level` (and implied `version: v3`) through credential-rule
  resolution, SNMP/mapper compilers, agent mapper JSON, and the discovery proto.
- Normalize protocol identifiers so `SHA-256` / `SHA256` / `sha256` (and the AES
  equivalents) all select the same gosnmp algorithm. Reject unknown identifiers
  instead of falling through to no-auth.
- Infer SNMPv3 from a v3 credential-rule payload even when the parent profile
  record is still v2c, so a UniFi-style single password (SHA + AES, same value
  for auth and privacy) compiles as `authPriv`.
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
    `elixir/serviceradar_core/lib/serviceradar/credentials/native_descriptors.ex`,
    `elixir/serviceradar_core/lib/serviceradar/credentials/network_credential_rule.ex`
- Related in-flight change: `refactor-unified-credential-management` owns the
  credentials UI. This change flips SNMP onto credential rules (`supports_rules:
  true`) and adds the missing v3 fields; it does not restyle that UI.
- Out of scope: converting farm01 device configs (operator step after merge),
  SNMPv3 context names (see design open questions), SNMP trap ingestion, rewriting
  credential settings UI, putting SNMP material in Kubernetes/Vault secrets.
