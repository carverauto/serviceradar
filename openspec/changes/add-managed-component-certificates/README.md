# Managed component certificates: implementation handoff

The scope and online/offline enforcement contract are approved. Continue the
whole proposal; a completed mechanism test is not beta acceptance.

## Next agent prompt

The branch contains Go/Rust peer verification, Linux installation, authority
persistence, NATS authorization codec, and Erlang active-session enforcement.
Independent policy bootstrap, the managed CLI, and the authority APIs are in
the tree. Acceptance of the whole proposal is still unchecked.

The managed CLI install path is `js/cli/README.md`. Certificate lifecycle,
local leaf policy, collector gRPC policy, and peer policy are the docs named
from `docs/agent-runbooks.md`. This handoff does not record acceptance.

Priority order for what this note still leaves open:

1. Run the complete host and cluster acceptance matrix in tasks.md. Live
   enrollment against a broker is not part of that unchecked acceptance.

Managed component certificates are ordinary PKIX names plus stored
fingerprints. SPIRE is not used on this path. Hub leaf observation reads the
presented certificate from an authenticated CONNZ listing; LEAFZ has no peer
certificate on NATS 2.14. Revocation sends KICK, which closes a leaf, and the
callout rejects the same certificate on reconnect. The chart leaves that
callout disabled until operator adoption and does not open an unbound leaf
listener. Local leaf listener enforcement is distinct from hub enforcement.
NATS operator/JWT mode and direct Rust gRPC receiver integration remain unproved.
Deployment must explicitly enable TLS for the Erlang peer mesh before claiming
certificate revocation covers that transport. Installation and service activation
are not receiver-confirmed certificate use.

## Current evidence

- Packaged NATS accepts the production Elixir authorization response. Targeted
  hub-side leaf/client revocation closes sessions and rejects reconnects while
  an unaffected leaf still delivers application messages. Invalid signatures,
  wrong issuer audience and expired requests are rejected. Existing client and
  leaf grants also expire when the authorization service disappears.
- Go real gRPC streams and Rust real NATS/TLS sockets close on revocation and
  policy expiry. Control peers with the same certificate serial survive.
- Real Erlang TLS distribution tests close incoming and outgoing revoked links,
  preserve control peers, reject reconnects and recover after policy refresh.
- Linux helper tests cover durable CSR reuse, paired NATS installation,
  intermediate chains, restrictive umask, activation failure and rollback.
  Collector listener identities require both client and server certificate use.
  These tests do not prove a real service is configured to use the installed paths.
- Agent adapter full remote unit gate passes. Combined-branch full gate and
  no-mistakes publication are still required.

Private deployment receipts and test invocation links stay outside the repo.
The design and choices ledger own enduring contracts, not test transcripts.
