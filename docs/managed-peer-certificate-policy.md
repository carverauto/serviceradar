# Managed peer certificate policy

Managed peer admission supplements normal certificate-chain and hostname
verification with the authority's full-DER SHA256 allowlist. Certificate serials
are not revocation identities. A configured peer with no fresh policy is denied;
active managed connections close when their certificate is removed or the policy
lease expires.

## Erlang releases

Core, agent-gateway, and web releases enable managed TLS distribution when either
policy setting is present. Both settings are required:

- `SERVICERADAR_CERT_POLICY_URL`: HTTPS URL ending in
  `/.well-known/serviceradar/certificate-policy`.
- `SERVICERADAR_CERT_POLICY_KEY_FILE`: root-owned, non-writable-by-group-or-world
  file containing the base64-encoded, raw 32-byte Ed25519 policy public key.
- `SERVICERADAR_CERT_POLICY_CA_FILE`: optional private HTTPS CA bundle. Omit it
  to use the normal HTTPS trust roots.
- `SERVICERADAR_DIST_CERT_FILE`, `SERVICERADAR_DIST_KEY_FILE`, and
  `SERVICERADAR_DIST_CA_FILE`: the enrolled node's certificate, private key, and
  peer CA bundle. The certificate must support both TLS client and server roles
  and the node hostname or IP used by distribution.

Install the dedicated policy public key through the trusted enrollment or
operator configuration channel, independently of the policy response. Do not
replace it with a key supplied by the policy endpoint itself.

The release selects `serviceradar_core/priv/managed_ssl_dist.config`. OTP evaluates
this packaged configuration before application startup; certificate directories
remain read-only. Managed distribution uses TLS 1.3, requires client
certificates, and disables TLS session resumption. Missing files fail startup.
Without policy configuration, the release retains its existing distribution
configuration; installing certificates alone does not establish that TLS
distribution is enabled.

Enroll every node's certificate before changing a deployment's distribution
transport. Plain and TLS distribution nodes cannot form one mesh, so plan the
transition for the entire peer set. Roll back the transport settings for the
entire peer set if a rollback is needed. Do not claim enforcement on a replica
that has not adopted the managed configuration.

## Independent refresh and recovery

`PeerCertificatePolicySupervisor` starts a replica-local policy store, transport
guards, and an HTTPS refresher. The refresher polls every five seconds. Its HTTPS
connection uses ordinary PKIX and hostname checks and the existing egress-proxy
client, without depending on ERTS or NATS admission. This lets a gateway recover
from an expired policy even when all its node connections have closed.

The response is a JSON envelope with base64 `payload` and `signature` fields.
Ed25519 verifies the exact decoded payload bytes prefixed by
`serviceradar.certificate-policy.v1` and one zero byte. The encoded envelope is
bounded to 4 MiB. The decoded transport fields are `version`, `generated_at`,
`valid_until`, and `allowed_fingerprints`; additional signed authority fields do
not change TLS membership checks. The store accepts at most a 30-second lease,
allows at most five seconds of future clock skew, and rejects policy rollback.
Replaying an identical response never extends its local monotonic deadline.

Use `ServiceRadar.Security.PeerCertificatePolicy.status/0` for local freshness
and active, closing, or failed transport counts. The refresher's `status/1`
reports its last successful refresh and last error. A failed close remains a
failure and is retried; it is not an enforcement receipt. Transport guards
monitor their policy store and close their connections if it exits. The
supervisor then fetches fresh authenticated state before admitting peers again.

`ssl_options/2` composes the policy with an existing SSL verifier. Distribution
uses the pinned OTP's per-connection verification process as its close owner;
`gnat_options/3` binds a named Gnat connection during its verified handshake.
Unmanaged callers must not attach these managed options implicitly.

## Executable compatibility proof

Run the focused remote target:

```text
bazel test --config=remote //elixir/serviceradar_core:peer_certificate_distribution_test --test_output=errors
```

It uses synthetic certificates, real SSL and Gnat sockets, and four isolated
OTP nodes. It executes the core, gateway, and web release environment templates,
fetches signed policy over HTTPS before node admission, selectively closes
incoming and outgoing node sessions, rejects reconnects and forged updates,
checks expiry, and recovers after a policy-store restart. The control connection
and peer VMs survive selective revocation. Removing the active close operation
must leave revoked node links connected and fail the test.
