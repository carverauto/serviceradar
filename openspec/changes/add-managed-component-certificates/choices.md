# Implementation choices

These entries describe implementation decisions beyond the approved product
scope. Pending proofs remain acceptance work, not evidence of working behavior.

## Sound, medium confidence

### Keep freshness enforcement at the hub while preserving offline local ingestion

The user explicitly chose continued local ingestion during a WAN outage. Local
collectors may use the last verified policy only for their enrolled leaf's
configured endpoint and certificate identity. The UI reports stale policy;
ordinary TLS verification and certificate expiry remain enforced. Previously
learned revocations are not forgotten. Hub, core and gateway authorization still
requires fresh policy and applies current revocations on reconnect.

The initial thirty-second cutoff for every receiver was rejected because it
would stop local ingestion during the outage it is meant to withstand. A
thirty-second freshness lease with ten-second refresh remains an implementation
choice for central receivers, subject to runtime and recovery proof.

### Treat service activation and certificate use as separate evidence

After installation, the helper reloads or restarts the fixed service and checks
that systemd considers it active. It reports that result but does not retire the
old certificate. The service could still reference its old certificate path;
only a receiver observing the successor establishes use. NATS uses
reload-or-restart so initial enrollment can start an inactive service. Collectors
restart because their TLS configuration retains the old certificate in memory.

The plan required supported activation but left the per-service operation open.
This choice is sound and exposes a real limitation rather than interpreting
process success as TLS success. Host-level adoption/reload still needs proof.

### Preserve existing collector configuration shapes

A managed collector receives an explicit policy-file setting in its existing
TLS configuration. The shared Rust policy crate implements verification and
expiry, while each collector retains its own config layout and holds the guard
for as long as a client can publish. Existing installations without that setting
keep their current behavior; a configured missing or invalid policy fails closed.

The plan did not prescribe a common config schema. Preserving the existing
layouts avoids an unrelated migration while one shared implementation prevents
five divergent revocation rules. Future client clones must retain that guard.

## Sound, high confidence

### Identify certificates by the entire DER fingerprint

Two certificates can have the same issuer and serial number. Revoking one must
not disconnect the other. The authority and receivers use a SHA-256 fingerprint
of the complete certificate bytes, with ordinary CA and hostname verification
still required first. The plan excluded serial-only identity but did not select
the representation. This gives every language the same unambiguous identity.

### Authenticate policy updates independently of the agent process

Core signs the exact JSON policy bytes with a dedicated deployment Ed25519 key.
Enrollment pins only the public key in a root-owned file. The privileged helper
verifies the signature and freshness before atomically publishing policy.json;
a nonroot agent cannot claim that it already verified arbitrary replacement
bytes. Signatures include a certificate-policy purpose prefix. Release signing
keys and edge-record capability keys remain separate authorities.

The plan required trusted atomic installation but left this boundary unspecified.
This is sound because collectors trust the installed file's ownership. An older
timestamp is rejected; equal timestamps accept only byte-identical retries.

### Fetch policy through the existing authenticated gateway connection

An enrolled agent polls a small GetCertificatePolicy RPC carrying exact payload
and signature bytes. It does not create a persistent command row every ten
seconds and does not need an inbound port. The existing agent command channel
carries prepare/install work, whose receipts matter durably.

The plan left distribution transport open. This reuses the established mTLS
boundary and keeps a recurring read separate from durable operator commands.

### Keep private keys in fixed privileged host storage

The updater generates keys locally and preserves each prepare request's CSR for
retry. Installation stages immutable generation directories and atomically
switches a current link, including both NATS roles together. Fixed packaged
service users own private files; root owns the control metadata and directories.
The helper explicitly applies traversal modes so a restrictive caller umask
cannot make an otherwise valid installation unreadable.

The plan required local keys and atomic installation but left filesystem layout
and privilege separation open. Reusing the privileged updater fits the existing
nonroot agent and avoids arbitrary remotely supplied paths or shell commands.

### Preserve a working predecessor across activation failure

Before switching generations, the helper records the previous target. If
activation fails, it restores that target and reactivates the prior service.
Failure to restore or reactivate is reported as failed rollback, never success.
Retries reuse persisted state after process loss.

The plan required atomic installation and safe rotation. This implementation
choice makes failure recoverable without assuming a successful file rename
means the service changed identity.

### Use NATS authorization callouts and targeted disconnects at the hub

The broker verifies TLS and sends a signed authorization request to a protected
authorization account. Core checks the certificate fingerprint and issues the
scoped user response. Existing connections are addressed by server and connection
IDs for targeted disconnect. On NATS 2.14, `DisconnectClientByID` closes a leaf
as well as a client, and an authenticated CONNZ listing includes both. A CONNZ
lookup by connection id omits leaves, and LEAFZ has no peer certificate, so hub
observation reads `cert_sha256` from the authenticated listing. The packaged
broker proves both client and leaf disconnect support. Dynamic leaf TLS pin
reload is not the selected mechanism. The callout remains disabled in the
chart until an operator adopts it.

The plan explicitly required a compatibility proof before choosing this adapter.
This choice fits the tested hub boundary; it does not establish local leaf
listener or operator/JWT support without their separate proofs.

### Bootstrap peer policy through an independent signed HTTPS read

Core, gateway and web peers need policy before establishing their Erlang mesh.
Fetching initial policy through that same mesh would deadlock startup. A small
public HTTPS endpoint serves a signed envelope of fingerprints, generic NATS
permissions and validity timestamps. A pinned deployment public key authenticates
the policy; ordinary HTTPS certificate validation still applies. The endpoint
contains no private keys or component, host or site names.

### Bind offline permission to a stable leaf identity and endpoint

The root-owned collector binding names one endpoint and the leaf server DNS
name `<component-id>-server.<partition>.serviceradar`. Managed component
certificates are ordinary PKIX certificates: common name, DNS and IP names,
chain, expiry, and the stored fingerprint. This path does not require a
SPIFFE URI or a SPIRE runtime. Each actual certificate must also appear in
the last verified policy and pass normal TLS verification. Pinning one
certificate fingerprint in the binding would break legitimate rotation;
trusting every discovered server would widen the offline exception.
Discovery cannot silently switch this binding.

### Scope host identity to the packaged service instance

Log pipelines and flow protocols share packaged service processes. Giving each
pipeline a different certificate would require separate processes and service
units. Enrollment therefore manages one component per host and fixed service,
preserves other enabled pipelines, and explicitly rejects conflicting enrollment.
This is the initial supported catalog, not independent per-pipeline identities.

### Bound hub grants even when the authorizer disappears

A hub authorization grant expires with its current short policy lease. The broker
therefore closes connections even if the authorization worker dies before sending
a targeted disconnect. Healthy clients must reconnect periodically as a result.
Real-broker expiry is proved; reconnect overhead and application continuity still
need acceptance measurements before the chosen lease is considered settled.

### Allow collector certificates to serve approved listeners

A collector can be both a NATS client and a TLS server. Its assignment may include
approved listener names, and installation validates both certificate uses. Names
come from the authorized assignment, not an unrestricted CSR. This preserves
existing TLS listeners without adding a second certificate role to every service.
