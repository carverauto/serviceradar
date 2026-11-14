# Design: fail-closed SNMPv3 security levels

## D1 — Refuse at the earliest Elixir point, skip with a warning

`ProtocolFormatter.security_level/1` is the choke point all three compile
paths share. It changes from a total function with a silent default to a
refusal: unknown input (including nil? — see D2) no longer yields
`"noAuthNoPriv"`. The exact shape (tagged tuple vs nil + explicit check)
follows the codebase's existing refusal idiom at the call sites:

- `SNMPCompiler`: resolution already returns `{:error, reason}` for refused
  credentials and the compiler skips with `log_credential_refusal`. An
  unknown level becomes another refusal reason, failing the *device*, never
  the whole compile (except credential-read failures, which already fail
  the compile by design).
- `to_mapper_credentials/1` and the sync/agent-config paths: same rule —
  no wire string is ever produced for an unknown level.

This keeps one definition of "known level" (`normalize_security_level`
plus the three atoms) and makes the fallback literally unspellable at the
type level.

## D2 — Absent is not invalid

Nil (level never set) keeps today's inference: resolver
`infer_security_level`, sync-change password inference, Go `""` handling.
Only *present-but-invalid* refuses. Broker resolution is where this
distinction matters most: `broker_security_level` currently collapses both
to nil. It must return `{:error, {:unknown_security_level, value}}` for a
present-but-unrecognised string while still inferring when the key is
absent. Record-side levels come from Ash-validated attributes, so they are
already constrained; legacy raw records flow through the same refusal.

## D3 — Go last mile errors on UNSPECIFIED

`protoToSNMPSecurityLevel` gains an error return (or maps to the existing
`ErrUnknownSNMPSecurityLevel` family) for `UNSPECIFIED` and unmapped
values. After D1 core can no longer emit `UNSPECIFIED` for an explicit
level, so this is unreachable in practice — defense in depth at the trust
boundary, and it makes the agent's behavior match its own string parser,
which already errors. `""` string handling is untouched.

## D4 — Tests at the wire boundary, no live system

- SNMP: unit tests asserting unknown level strings/atoms refuse at each
  Elixir choke point (compiler skips with warning, resolver errors,
  broker refuses explicit garbage but still infers absent) plus the Go
  `UNSPECIFIED` error case; the shared contract fixture keeps pinning the
  three valid levels on both sides. Fixtures are invented, never taken from
  a live system.
- Every regression fails first on the unfixed tree.
