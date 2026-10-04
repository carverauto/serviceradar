# Authenticate flow exporters (#5015)

## Why

NetFlow v9 and IPFIX datagrams reach the parser using an unauthenticated UDP
source address and an attacker-controlled observation domain. Spoofing those
values changes local templates, sampling state and pending records, and writes
or withdraws templates in the shared NATS KV store. An IP allowlist or disabling
KV alone does not close the local poisoning path.

## What changes

- Add native IPFIX over mutually authenticated TLS/TCP, using RFC 7011 message
  lengths and port 4740 by default. Verify the client chain and an explicit
  operator-approved exporter certificate identity before invoking any parser.
- Keep parser, template, pending-record and sampling state inside each verified
  transport session. Never restore templates from another session or from the
  existing UDP KV namespace. Native TLS ingestion does not use shared KV.
- Reject template-based NetFlow v9/IPFIX on UDP by default, before admission or
  parsing. Keep template-free NetFlow v5 and sFlow UDP ingestion available.
- Provide an explicit `allow_unauthenticated_templates` compatibility opt-in
  for legacy UDP exporters. It has no shared template store, is clearly marked
  insecure, and does not claim resistance to source-address spoofing.
- Update shipped configurations and chart defaults to disable shared UDP
  template persistence and expose optional IPFIX TLS configuration.
- Bound concurrent sessions, sessions per approved exporter, handshake time,
  idle/read time and message size, and expose authentication/rejection metrics.

## Compatibility decision requiring approval

Existing NetFlow v9 and UDP IPFIX exporters stop ingesting templates with secure
defaults. They must migrate to authenticated IPFIX, or their operator must
explicitly accept the insecure UDP compatibility mode on a protected network.
Devices that only support NetFlow v9 need a separately protected gateway/network
boundary; this change does not invent an authenticated identity for their UDP
packets. Existing unauthenticated KV entries are not migrated or restored.

If retaining UDP template ingestion with cryptographic authentication and shared
restart persistence is mandatory, use a separately scoped DTLS design instead;
that requires a new transport dependency and interoperability validation.

## Impact

Affected capability: flow-collector. Affected code: Rust collector ingress,
configuration, metrics and existing parser lifecycle; shipped collector/Helm
configuration and operational documentation. Flow conversion and NATS publishing
contracts remain in place. No telemetry database writes or device credential
stores are added.

Status: approved by the user on 2026-10-03; implementation in progress.
