# Authenticated IPFIX ingress

## Current boundary

`main.rs` binds a UDP socket. `Listener::run` passes `recv_from`'s peer directly
to `NetflowHandler::parse_datagram`, which admits the source and invokes
`AutoScopedParser` before flow filtering. The parser scopes templates by address
and observation domain; the NATS adapter persists those scopes unchanged in
meaning. Every local/shared template kind, withdrawal, pending record and sampler
must therefore be protected before parsing rather than after conversion.

## Decisions

1. Add an `ipfix_tls` listener with required server certificate/key, client CA,
   and nonempty approved exporter certificate SHA-256 fingerprints mapped to
   operator-defined exporter IDs. Require ordinary rustls chain, validity and
   handshake proof-of-key verification in addition to the approved identity
   mapping. A client trusted by the CA but absent from the mapping is rejected.
   Public fingerprints are configuration, not stored device passwords.
2. Use existing workspace rustls, tokio-rustls and rustls-pemfile dependencies.
   Accept TLS 1.2/1.3 using repository crypto-provider conventions; disable early
   data. Finish verification before creating or invoking the flow parser.
3. Frame only native IPFIX version 10 using the message header Length field.
   Require 16 <= length <= configured message bound <= 65535. Read exactly one
   complete message at a time; partial or invalid frames terminate the session.
   Do not guess NetFlow v9 stream framing or fall back to plaintext.
4. Each admitted TLS session owns a separate handler and local state, retaining
   observation-domain separation inside that handler. Drop all its state on
   disconnect. Do not start permanent template-metrics tickers for session
   handlers or attach shared KV. RFC 7011 section 8 prohibits using templates
   from a different transport session, including a reconnect by the same peer.
5. Apply a listener-wide session semaphore before handshake, a bounded handshake
   timeout, and an approved-exporter session bound after authentication. Bound
   reads/idle time and bytes before allocation. No unbounded spawn or identity
   registry. Account rejected identities without unbounded metric labels.
6. Gate UDP versions 9 and 10 before parser admission. Default deny. The explicit
   insecure opt-in uses its own listener-local handler and never shared KV.
   Template-free legacy versions and sFlow retain existing behavior.
7. Shipped template-store defaults become disabled. Do not delete existing KV
   data as part of migration, but do not read or write it from either TLS or
   insecure UDP paths. Document that persistence was based on untrusted identity.

## Alternatives

Source IP allowlists cannot authenticate a spoofed source. A store-only guard
leaves local templates and sampling vulnerable. Reusing a handler keyed only by
the UDP tuple allows identity collisions. Merely setting a builder store scope
does not work: AutoScopedParser replaces it with its own tuple/domain scope.
Certificate-only shared scopes also incorrectly restore prior TLS-session
templates. DTLS could retain UDP framing, but is a separate dependency and
deployment/interoperability choice.

## Verification

Use invented certificates, exporter identities, addresses and wire messages.
Exercise native handshake/ingress: no certificate, wrong CA, trusted-but-unlisted
identity, plaintext spoof, and invalid/partial/oversized message frames must not
reach parser state. Valid approved exporter templates and data must convert and
publish. Same tuple/domain/template ID across two authenticated sessions must not
share templates; reconnect must require a new template. Test withdrawals,
options/sampler state, insecure UDP separation and UDP default rejection.

Check bounded sessions and handshake/read timeouts. Run formatting and diff
checks locally; compile and execute owner tests on RBE/PR BazelCI only. Live
testing uses synthetic traffic in isolated demo resources, not harvested device
data. Report any interoperability scenario not exercised.

Primary protocol reference: https://www.rfc-editor.org/rfc/rfc7011.html
