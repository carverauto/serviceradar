# Proposal: fail-closed SNMPv3 security levels

## Problem

Two credential-handling defects, both silent downgrades.

**SNMPv3 security level.** An unrecognised security level falls back to
`noAuthNoPriv` instead of refusing. The chain, verified in tree:

- `ProtocolFormatter.security_level/1` maps unknown/nil to `"noAuthNoPriv"`.
  Callers are the profile compiler (`SNMPCompiler.compile_v3_auth`), the
  mapper-credentials path
  (`CredentialResolver.to_mapper_credentials/1`), and the sync target path.
- `SNMPProtoMapper.security_level/1` maps unknown/nil to
  `:SNMP_SECURITY_LEVEL_UNSPECIFIED`, and Go `protoToSNMPSecurityLevel`
  maps `UNSPECIFIED` (and anything unmapped) to `NoAuthNoPriv`.
- A typo'd level with passwords present therefore compiles to an
  unauthenticated, unencrypted poll: `valid_v3_secrets?` matches the
  fallback level and asks for no passwords.

The Go string parsers already fail closed (`securityLevelToMsgFlags` and
`snmpv3MsgFlags` return `ErrUnknownSNMPSecurityLevel` on unknown input);
only the Elixir compile paths and the proto-enum last mile do not. Ash
resource writes already reject unknown levels (`one_of` on the
`:security_level` attribute), so save-time validation stands — except for
broker payloads, which are resolved, not saved: an explicit-but-invalid
level in a broker secret normalizes to nil and is then *inferred* from the
passwords, silently ignoring what the operator wrote.

## What this changes

1. Elixir compile paths refuse unknown levels: `security_level/1` stops
   defaulting, broker resolution distinguishes absent (infer, as today)
   from present-but-invalid (refuse with `{:error, ...}`), and the SNMP
   compiler skips the device/target with its existing credential-refusal
   warning instead of compiling `noAuthNoPriv`. `SNMPProtoMapper` keeps
   `UNSPECIFIED` for absent (proto3 zero value) but core never emits it for
   an explicit level again.
2. Go last mile: `protoToSNMPSecurityLevel` returns an error on
   `UNSPECIFIED`/unmapped instead of `NoAuthNoPriv`. The `""` empty level in
   string configs keeps its current infer/default behavior (unchanged
   contract, pinned by the shared fixture).

## What this does NOT change

- The three valid levels and every spelling the forms/contract accept
  behave byte-identically (shared fixture `snmpv3_protocol_contract.json`
  pins them across core and Go).
- Absent-level inference (nil → passwords decide) is preserved in the
  resolver, the sync change, and the Go `""` handling: only explicit
  garbage refuses.
- No new credential storage: secrets stay in env/config as today.
- Cold tier (`ColdTier.Head` SQL interpolation, the two raw-inspect error
  sites) is out of scope for this change: cold tier only archives the
  telemetry tables StarRocks owns when enabled, so it is inert on
  StarRocks installs, and it is disabled on demo. Its credential handling
  is recorded here as a known defect for whoever owns that subsystem, not
  fixed here.
