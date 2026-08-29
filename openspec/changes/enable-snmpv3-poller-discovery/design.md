## Context

Issue 4149: SNMPv3 exists in the UI and in compiled agent config, but has never
been tested on a real network. Farm01 is the intended live proving ground. The
operator will convert farm01 devices from SNMPv2c community auth to SNMPv3 after
this change is on the cluster.

Current surfaces that already mention v3:

- Settings SNMP profile form and device credential editor
  (`elixir/web-ng/.../snmp_profiles_live`, `device_edit_components.ex`)
- Native SNMP credential descriptor v3 method
  (`ServiceRadar.Credentials.NativeDescriptors`)
- SNMP compiler `v3_auth` payload and `ServiceRadar.Edge.SNMPProtoMapper`
- Poller proto `monitoring.SNMPv3Auth` and `go/pkg/agent/snmp` USM client
- Mapper `SNMPCredentials` (username / auth / privacy) and
  `DiscoveryEngine.configureClientVersion`

What does *not* work end-to-end:

1. Mapper always sets `client.MsgFlags = gosnmp.AuthPriv` and never sets
   `client.SecurityModel = gosnmp.UserSecurityModel`.
2. Mapper `SNMPCredentials` and `mapperCredSpec` have no `security_level`.
   `CredentialResolver.to_mapper_credentials/1` therefore drops it.
3. Mapper protocol matching is an exact `ToUpper` on compact names
   (`SHA256`, `AES256`). Hyphenated compiler output (`SHA-256`) is ignored and
   gosnmp is left at `NoAuth` / `NoPriv` with no error.
4. Native v3 descriptor fields are `username`, `auth_protocol`, `auth_password`,
   `priv_protocol`, `priv_password`. There is no `version` or `security_level`.
   `broker_json_credential/3` then falls back to the parent record's version,
   defaulting to v2c, and the compiler skips the target for a missing community.
5. Discovery proto `SNMPCredentials` has no security-level field, so gRPC-started
   jobs cannot express `authNoPriv` / `noAuthNoPriv`.
6. Tests assert compiled JSON / proto shape. Nothing opens a USM session.

Farm01 verification is intentionally *after* implementation: convert the
switches/routers to SNMPv3, point the existing SNMP profile / credential at that
user, and watch mapper + poller against the live estate.

## Goals / Non-Goals

- Goals:
  - Poller GET/walk and mapper discovery/topology both succeed against SNMPv3
    `authPriv` (the farm01 target) and the other two USM levels.
  - A v3 credential secret is enough to compile v3 sessions even if the profile
    row still says v2c.
  - Auth failures are visible as auth failures, not empty discovery or a silent
    skip.
  - v1/v2c keep working; VLAN `community@vlan` indexing stays v1/v2c-only.
- Non-Goals:
  - Changing farm01 device configuration in this repo.
  - SNMPv3 context names / non-default contexts (open question).
  - SNMP trap v3 ingestion.
  - Replacing the unified credential settings UI
    (`refactor-unified-credential-management`).
  - Supporting HMAC-SHA2 / AES-256-C Blumenthal vs Reeder variants beyond what
    gosnmp already exposes (`AES192`, `AES256`, `AES192C`, `AES256C`).

## Decisions

- **Decision: One USM setup helper shared in spirit, two call sites.**
  Poller (`go/pkg/agent/snmp`) and mapper (`go/pkg/mapper`) already have separate
  gosnmp wrappers. Do not merge them into one package in this change. Both MUST
  apply the same rules: `Version3` + `UserSecurityModel` + MsgFlags from security
  level + auth/priv protocols from a shared identifier table + error on unknown
  identifier. Duplicate the small mapping table rather than introduce a new
  shared SNMP-USM crate/package.

  Alternatives considered: extract `go/pkg/snmpusm`. Rejected for this change;
  the bug is incomplete wiring, not missing abstraction. Revisit if a third
  client appears.

- **Decision: Normalize protocol identifiers at the Go client boundary.**
  Accept compact (`SHA256`), hyphenated (`SHA-256`), and case-insensitive aliases.
  Elixir `ProtocolFormatter` already has both styles (poller JSON is hyphenated,
  mapper JSON is compact). Fixing only one compiler style leaves the other
  client broken. Reject unknown values instead of defaulting to `NoAuth`/`MD5`/
  `DES`.

- **Decision: Infer version and security level from the secret when omitted.**
  If the resolved credential has a username or auth/priv material, version is
  `v3`. Security level: explicit value wins; otherwise `priv_password` present →
  `authPriv`, `auth_password` present → `authNoPriv`, else `noAuthNoPriv`.
  Add `security_level` (and keep protocols) on the native v3 descriptor so newly
  created unified secrets are self-describing. Do not require operators to also
  flip the profile version dropdown for a bound v3 secret to take effect.

- **Decision: Add `security_level` to discovery proto `SNMPCredentials`.**
  Mapper JSON already needs it for scheduled jobs. gRPC `StartDiscovery` uses the
  same struct. Without the field, ad-hoc discovery cannot express non-`authPriv`
  v3. Default when unset: infer from whether auth/priv passwords are present
  (same rule as the compiler). This is additive proto; old senders remain valid.

- **Decision: Farm01 is `authPriv` until proven otherwise.**
  Hermetic tests cover all three levels. Live verification on farm01 is
  `authPriv` with SHA (or SHA-256) + AES (or AES-256), matching the Cisco
  example in `docs/docs/device-configuration.md`. If farm01 lands on a different
  combo, the identifier table already includes it.

- **Decision: No SNMPv3 context name in this change.**
  gosnmp `ContextName` stays empty (default context). The Cisco doc example uses
  a named context; farm01's current v2c estate does not. If conversion requires a
  context, add it as a follow-up field on the credential rather than guess now.

- **Decision: Fail closed on incomplete v3 config.**
  `authPriv` without both protocols and both passwords is an error. `authNoPriv`
  without auth protocol/password is an error. Mapper MUST NOT open a session
  that claims `AuthPriv` with empty passphrases. Today's silent `NoAuth` fallback
  is the behavior we are removing.

## Risks / Trade-offs

- **Farm01 cutover will drop v2c** → keep v2c code paths; only the farm01
  credential/profile changes. Roll back by restoring the v2c community on the
  devices and the profile.
- **Wrong security level after inference** → prefer explicit `security_level` on
  new secrets; inference is a compatibility bridge for secrets created before
  the descriptor grows the field.
- **gosnmp AES-256 vs Cisco "aes 256"** → use gosnmp `AES256` for the farm01
  default. If a device negotiates Blumenthal (`AES256C`) instead, the UI already
  lists AES-256-C; add a farm01 note rather than auto-detecting.
- **Discovery proto field add** → regenerate Go + Elixir stubs; old agents ignore
  unknown fields, old cores omit the field, inference covers them.
- **Overlap with unified credential management** → additive descriptor fields
  only. Do not restyle the credentials UI here.

## Migration Plan

1. Land the code on a feature branch, unit/hermetic tests green.
2. Roll the farm01 agent (mapper + poller) *before* converting devices, so v2c
   keeps working.
3. Operator converts farm01 SNMP to v3 `authPriv`, updates the SNMP credential /
   default profile, waits for agent config push.
4. Verify mapper job produces device/interface/topology results and poller
   writes SNMP metrics for a known farm01 switch.
5. If verification fails, restore v2c on the devices; the new code still speaks
   v2c.

No schema migration. Descriptor field additions are backward compatible.

## Open Questions

- Does farm01 need a non-default SNMPv3 context name? If yes, add `context_name`
  to the credential and set gosnmp `ContextName`.
- Exact farm01 USM combo (SHA vs SHA-256, AES vs AES-256) — confirm when the
  devices are converted; both are already in the identifier table.
- Are there farm01 devices that must stay on v2c during a mixed estate? Target
  specific credentials already exist (`TargetSpecific` / device overrides) and
  should keep working; call that out in the farm01 checklist if mixed mode is
  required.
