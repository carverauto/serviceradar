# Managed component certificates: implementation handoff

The scope and online/offline enforcement contract are approved. Continue the
whole proposal; a completed mechanism test is not beta acceptance.

## Next agent prompt

Connect the integrated durable authority and signed policy to the remaining
receivers and host onboarding. The branch contains Go/Rust peer verification,
Linux installation, authority persistence, NATS authorization codec and Erlang
active-session enforcement. Independent policy bootstrap, managed CLI lifecycle
and authority APIs are in parallel implementation.

Priority order:

1. Finish central and local NATS authorization using one signed permissions map;
   prove local ingestion continues during WAN loss and fresh revocation closes it.
2. Integrate independent HTTPS policy refresh and TLS distribution boot, then
   cover remaining inbound Rust gRPC listeners.
3. Complete lifecycle reconciliation and receiver-observed successor retirement;
   add operator inventory/actions and CLI enrollment/adoption.
4. Populate the collector-facing leaf URL during enrollment, expose explicit
   Helm/Compose upstream advertisement, and bind all names to certificate SANs.
5. Run the complete host and cluster acceptance matrix in tasks.md.

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
