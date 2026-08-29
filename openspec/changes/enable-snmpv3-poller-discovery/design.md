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

Farm01 verification is intentionally *after* implementation. Observed 2026-08-29:

- UniFi SNMP UI exposes v2c community **and** v3 username + a **single** password.
  UniFi hard-codes USM **SHA + AES-128 authPriv** and uses that password for both
  auth and privacy. ServiceRadar must compile that as a credential **rule**, not a
  profile-bound secret.
- Native SNMP descriptor currently has `supports_rules: false`, so the UI hid SNMP
  from New Rule. Farm01 stored a standalone `snmp-v3` secret on the default profile
  instead. Mapper picked it up and then failed 61 IPs with
  `the SNMPV3 User Security Model is the only SNMPV3 security model currently implemented`.
- The k8s agent is `192.168.2.121`. UDM-Pro `farm01` has confirmed aliases
  `192.168.1.1` and `192.168.2.1`. Poller target `snmp_192_168_1_1` times out
  because the worker cannot reach the WAN-side address; poll `192.168.2.1`.

## Goals / Non-Goals

- Goals:
  - Poller GET/walk and mapper discovery/topology both succeed against SNMPv3
    `authPriv` (the farm01 target) and the other two USM levels.
  - SNMP credentials come from credential rules in CNPG. A v3 rule is enough to
    compile v3 sessions even if the parent profile row is still v2c.
  - Auth failures are visible as auth failures, not empty discovery or a silent
    skip.
  - v1/v2c keep working; VLAN `community@vlan` indexing stays v1/v2c-only.
- Non-Goals:
  - Changing farm01 device configuration in this repo.
  - SNMPv3 context names / non-default contexts (open question).
  - SNMP trap v3 ingestion.
  - Replacing the unified credential settings UI
    (`refactor-unified-credential-management`).
  - Storing SNMP/UniFi/device material in Kubernetes Secrets, Vault, Helm, or env.
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

- **Decision: SNMP credentials are credential rules, not secrets.**
  Flip `NativeDescriptors.snmp()["supports_rules"]` to `true`. Poller and mapper
  compilers resolve `NetworkCredentialRule` rows for provider `snmp` / purpose
  `snmp_monitoring` (scope = the compiling agent, target_query matches the
  device). The encrypted payload behind the rule may live in
  `network_credential_secrets` as `rule.secret_id` — that is ciphertext for the
  rule, not an operator-facing secret and not a Kubernetes Secret. Do not add a
  new profile/device/job `credential_secret_id` product path. Existing
  profile-bound secrets are legacy and MUST NOT win over a matching rule.

- **Decision: Infer version and security level from the rule payload when omitted.**
  Username or auth/priv material implies version `v3`. Explicit `security_level`
  wins. UniFi's SNMP UI is one password with hidden SHA + AES-128 `authPriv`.
  The native v3 descriptor MUST include `security_level`, `auth_protocol`, and
  `priv_protocol`. If `priv_protocol` is set and `priv_password` is blank, reuse
  `auth_password`. Do not default unknown protocols to MD5/DES. Farm01's rule is
  `authPriv` / SHA / AES with the UniFi password in both fields.

- **Decision: Add `security_level` to discovery proto `SNMPCredentials`.**
  Mapper JSON already needs it for scheduled jobs. gRPC `StartDiscovery` uses the
  same struct. Without the field, ad-hoc discovery cannot express non-`authPriv`
  v3. Default when unset: infer from whether auth/priv passwords are present
  (same rule as the compiler). This is additive proto; old senders remain valid.

- **Decision: Farm01 UniFi USM combo is SHA + AES-128 `authPriv`.**
  Confirmed from the UniFi Network SNMP screen: Version 3, username
  `serviceradar`, one password. UniFi does not expose protocol or security-level
  controls. Poll the UDM from the k8s agent at `192.168.2.1`, not `192.168.1.1`.
  Hermetic tests still cover all three USM levels.

- **Decision: No SNMPv3 context name in this change.**
  gosnmp `ContextName` stays empty (default context). The Cisco doc example uses
  a named context; farm01's current v2c estate does not. If conversion requires a
  context, add it as a follow-up field on the credential rather than guess now.

- **Decision: Fail closed on incomplete v3 config.**
  After inference (including copying auth password into privacy when
  `priv_protocol` is set), `authPriv` without both protocols and both passwords
  is an error. `authNoPriv` without auth protocol/password is an error. Mapper
  MUST NOT open a session that claims `AuthPriv` with empty passphrases. Today's
  silent `NoAuth` / MD5 / DES fallback is the behavior we are removing.

## Risks / Trade-offs

- **Farm01 cutover will drop v2c** → keep v2c code paths; only the farm01
  credential/profile changes. Roll back by restoring the v2c community on the
  devices and the profile.
- **Wrong security level after inference** → prefer explicit `security_level` on
  new rules; inference is a compatibility bridge for UniFi's single-password UI
  and for payloads created before the descriptor grows the field.
- **UniFi AES-128 vs gosnmp AES** → farm01 uses UniFi's AES-128 (`gosnmp.AES`),
  not AES-256. The identifier table still includes AES256 for other vendors.
- **Discovery proto field add** → regenerate Go + Elixir stubs; old agents ignore
  unknown fields, old cores omit the field, inference covers them.
- **Overlap with unified credential management** → additive descriptor fields
  only. Do not restyle the credentials UI here.

## Migration Plan

1. Land the code on a feature branch, unit/hermetic tests green.
2. Roll the farm01 agent (mapper + poller) *before* converting devices, so v2c
   keeps working.
3. Operator creates an SNMP credential **rule** (v3 / SHA / AES / authPriv,
   UniFi password in both fields, scope the k8s agent). Poll the UDM at
   `192.168.2.1`. Wait for agent config push.
4. Verify mapper job produces device/interface/topology results and poller
   writes SNMP metrics for a known farm01 switch.
5. If verification fails, restore v2c on the devices; the new code still speaks
   v2c.

No schema migration. Descriptor field additions are backward compatible.

## Open Questions

- Does farm01 need a non-default SNMPv3 context name? If yes, add `context_name`
  to the credential rule and set gosnmp `ContextName`.
- Mixed estate: UniFi still has v1/2C enabled, so v2c community still answers.
  Non-UniFi boxes (pve, etc.) may not share this USM user. Credential-rule
  `target_query` should select UniFi/SNMP-capable devices rather than `in:devices`
  blindly if some seeds are not v3.
- Should existing profile-bound `credential_secret_id` values be migrated into
  rules automatically, or left as legacy until the operator recreates a rule
  (farm01 will recreate)?
