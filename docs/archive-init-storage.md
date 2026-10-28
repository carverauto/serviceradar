# Isolated archive storage

One isolated storage process uploads and verifies frozen init, media and
manifest objects under independent short-lived installed authorities. It does
not enable recording, qualify a provider,
publish an archive, or authorize deletion of local media. Keep
`mediaStorage.enabled` and `webNg.archiveStorage.enabled` false until the
deployment has its own current evidence and infrastructure-installed identities.

The [init protocol](../openspec/changes/add-vms-storage-playback-engine/init-authority.md)
and [media upload protocol](../openspec/changes/add-vms-storage-playback-engine/media-upload.md)
own their byte paths; [archive publication](../openspec/changes/add-vms-storage-playback-engine/archive-publication.md)
owns manifest transfer and index publication. This page owns the Helm and
mounted-file contract for all three purposes. Existing qualification
receipts are diagnostics; they cannot substitute for applying fresh authority.
The separate [archive reader](../openspec/changes/add-vms-storage-playback-engine/archive-reads.md#isolated-installation)
has its own default-disabled installation, described below. Reader installation
does not enable recording or install upload authority.
Cloud provisioning and preservation remain tracked in
[control issue #182](https://github.com/carverauto/serviceradar-control/issues/182)
and [control issue #183](https://github.com/carverauto/serviceradar-control/issues/183).

## Installed files

Infrastructure custody supplies existing Kubernetes Secrets. Helm values contain
only their names, never credential bytes. These are ServiceRadar infrastructure
credentials; camera/device credentials remain in the unified CNPG model.

| Workload/value | Projected keys | Mount directory |
| --- | --- | --- |
| `mediaStorage.configSecretName` | `config.json` | `/etc/serviceradar/init-storage/config` |
| `mediaStorage.providerSecretName` | `credentials.json` | `/etc/serviceradar/init-storage/provider` |
| `mediaStorage.authSecretName` | `runtime-token`, `recorder-token` | `/etc/serviceradar/init-storage/auth` |
| `mediaStorage.tlsSecretName` | `tls.crt`, `tls.key`, `ca.crt` | `/etc/serviceradar/init-storage/tls` |
| `webNg.archiveStorage.configSecretName` | `config.json` | `/etc/serviceradar/archive-storage` |
| `webNg.archiveStorage.authSecretName` | configured `tokenSecretKey` as `token` | `/etc/serviceradar/archive-storage-auth` |
| `webNg.archiveStorage.tlsSecretName` | `tls.crt`, `tls.key`, `ca.crt` | `/etc/serviceradar/archive-storage-tls` |

The storage config accepts `schema_version: 1` with one complete `desired`
document, or `schema_version: 2` with a nonempty `purposes` map instead of
`desired`. The map accepts only `init`, `media` and `manifest`; each desired
operation must match its key (`init_put_verified_v1`, `media_put_verified_v1`
or `manifest_put_verified_v1`). A process accepts only installed purposes.
All purposes must share the binding, local storage lifetime, destination,
provider resource, endpoint type and complete credential identity. Their
revisions, digests, challenges, nonces and deadlines remain independent.
The complete config is bounded to 32 KiB.

Both versions contain installed `deployment_ref`, decimal-string `generation`,
`provider_credentials_file`, `listener` and `runtime`. The listener has `port`,
`certfile`, `keyfile`, `cacertfile`, `recorder_certificate_sha256` and `token_file`.
The runtime client has `base_url`, `certfile`, `keyfile`, `cacertfile` and
`token_file`. Use the mounted absolute paths. Provider credentials contain
`reference`, integer `generation`, `access_key_id` and `secret_access_key`; their
reference and generation must match every installed desired report.

The web config contains `schema_version: 1`, `deployment_ref`, decimal-string
`generation`, `storage_service_id`, `credential_reference`, decimal-string
`credential_generation`, `client_cert_sha256`, `cert_file`, `key_file` and
`ca_file`. Its origin must match the installed media administrator identity.
The pinned SHA-256 is over the storage client's DER certificate. Both listeners
require a trusted client certificate and the exact configured certificate pin,
plus their distinct bearer token. The storage token must differ from the account
and media administrator tokens; the recorder token must differ from the storage
token. Web projects only the runtime token even when both workloads use the same
authentication Secret. Web never mounts provider credentials.

Each token file must contain exactly 32 to 512 bytes, without leading or trailing
whitespace or a newline. Both the storage workload and the web listener reject any
other length, surrounding whitespace, or a newline at startup.

## Deployment and network contract

The private storage-control Service is `serviceradar-archive-storage-control`,
port 4002 by default; the storage Service is `serviceradar-media-storage`, port
4443. Set the config ports to the chart ports. Server certificates must contain
the DNS names clients actually use. Neither Service has a public Gateway route.
The storage certificate serves both its listener and its control client, so its
leaf must permit both server and client TLS authentication. Each peer must trust
its issuing CA chain. A server-authentication-only leaf can listen successfully
while its control challenge fails.
The storage process runs the core-elx release's dedicated `eval` entry point
with an empty release configuration and distribution disabled. It receives no
core cookie, CNPG/NATS credentials or Kubernetes API token.

Storage runs one replica with `Recreate` updates. Its network policy permits
recorder ingress, the private web control port, DNS in `kube-system`, and explicit
`mediaStorage.providerEgress.cidrs`/`port`. Set those to the provider or CONNECT
proxy, with `egressProxy` when required. The chart excludes storage from its broad
Kubernetes and Calico policies. Policies installed outside this chart can still
add permissions; the workload certificate, token and credential mounts remain
the application boundaries. A cluster must actually enforce NetworkPolicy for
the network restrictions to take effect.

Bump both relevant `revision` values after changing mounted configuration,
tokens or certificates. Files are loaded at boot; updating a Secret alone does
not install a new running identity. The revision annotation triggers rollout,
while the protocol's desired revision prevents replay. They serve different
purposes and both must be advanced when replacing an installation.

## Authority and failure behavior

Install and roll the web control listener first, and confirm its authenticated
HTTPS endpoint is reachable before starting the storage pod. Use an authenticated
`GET` of `/v1/init-authorities/challenge`, `/v1/media-authorities/challenge`
or `/v1/manifest-authorities/challenge` and expect HTTP 404: authentication runs before the unsupported method is
rejected. Do not POST a challenge as a preflight; that would consume the desired
revision with a different boot identity and nonce. The storage process posts
one challenge per installed purpose on its matching path, each with a
five-second transport cap. It has no automatic retry or renewal loop. Starting
both workloads simultaneously is not a readiness handshake. A failed startup challenge leaves that purpose unavailable until an
explicit new installation. Pod readiness alone never means storage authority.

On startup, storage loads its installed purposes and credentials, generates
one boot identity and issues each authenticated challenge. The media
administrator reads each challenge and applies its matching desired document
and nonce through the existing private administration API. The original
challenge expires in at most 30 seconds. Application, retry, status reads and wall-clock changes cannot
extend it. A restart needs a greater desired revision and a new challenge.

Each init request carries only an existing upload handle and bounded base64
bytes. A newly committed init grant permits one conditional PUT, followed by a
HEAD and an identity-bound range GET whose bytes must match the frozen SHA-256.
One deadline bounds provider work. A lost grant response, timeout or HTTP 412
never permits a second PUT. Verification and late observations are retained
separately from availability; retain local bytes on every outcome in this
checkpoint. Media and manifest recorder ingress use raw
`POST /v1/media-uploads` and `POST /v1/manifest-uploads`, respectively, under
their linked protocols. All purposes share one admission slot reserved before
reading any body. The chart does not install `VMS_MEDIA_UPLOAD_CONFIG`; that recorder file is separate from the
storage process's `VMS_INIT_STORAGE_CONFIG`.

Revoke denies later grants. An earlier init grant may finish within its original
five-second maximum. Media and manifest grants keep the deadlines in their
linked protocols. Revocation cannot cancel a request the provider already
received.
Expiry and stop do not prove drain, credential retirement, safe bucket
teardown or safe local deletion. Recording and archive readiness stay unavailable.
After expiry, status retains the historical `applied_revision` with
`remaining_ms: 0`; consumers must not use that revision alone as permission.

## Separate archive reader installation

`archiveReader.enabled` defaults to false. Enabling it installs the isolated
reader and its Web client configuration together; it requires `webNg.enabled`,
a nonempty `archiveReader.revision`, all six Secret references below, and explicit
`archiveReader.providerEgress.cidrs`. It does not require the upload service to
be running: historical reads use current archive proofs, independently of
recording admission or expired upload grants.

| Workload/value | Projected keys | Mount directory |
| --- | --- | --- |
| `archiveReader.configSecretName` | `config.json` | `/etc/serviceradar/archive-read-storage/config` |
| `archiveReader.providerSecretName` | `credentials.json` | `/etc/serviceradar/archive-read-storage/provider` |
| `archiveReader.authSecretName` in reader | `reader-token` as `token` | `/etc/serviceradar/archive-read-storage/auth` |
| `archiveReader.tlsSecretName` | `tls.crt`, `tls.key`, `ca.crt` | `/etc/serviceradar/archive-read-storage/tls` |
| `archiveReader.client.configSecretName` in Web | `config.json` | `/etc/serviceradar/archive-reader/config` |
| `archiveReader.authSecretName` in Web | `reader-token` as `token` | `/etc/serviceradar/archive-reader/auth` |
| `archiveReader.client.tlsSecretName` in Web | `tls.crt`, `tls.key`, `ca.crt` | `/etc/serviceradar/archive-reader/tls` |

The reader config contains exactly `schema_version: 1`, `binding_id`, the
original immutable `destination` document, `provider_credentials_file` and
`listener`. Set the credential path to
`/etc/serviceradar/archive-read-storage/provider/credentials.json`. That file
contains `reference`, integer `generation`, `access_key_id` and
`secret_access_key`. The listener contains `port`, `certfile`, `keyfile`,
`cacertfile`, `reader_certificate_sha256` and `token_file`; use the reader's
mounted absolute paths. Its certificate pin is the SHA-256 of the Web client's
DER certificate, not the server certificate.

The Web config contains exactly `schema_version: 1`, the same `binding_id`, its
canonical `destination_sha256` and `storage`. The storage connection contains
`base_url`, `certfile`, `keyfile`, `cacertfile` and `token_file`, using Web's
mounted absolute paths. With the default port, its base URL is
`https://serviceradar-archive-reader:4444`. Web receives no provider credential
file or provider endpoint. The chart owns `VMS_ARCHIVE_READER_CONFIG` and rejects
attempts to supply it through `webNg.extraEnv` or `extraEnvValueFrom`.

Use separate reader server and Web client certificates. The server leaf must
permit server authentication and contain the Service DNS name used by Web; the
client leaf must permit client authentication and match the installed pin.
Both trust stores must contain the appropriate issuing CA chain. Reader and
Web share only the reader bearer token, whose file must contain exactly 32 to
512 bytes without surrounding whitespace or a newline.

The chart rejects using the same Secret name for reader server/client TLS, or
reusing the configured writer provider, authentication or TLS Secret names.
Distinct names do not prove distinct credential bytes or read-only IAM rights.
Infrastructure custody must supply a dedicated read identity restricted to the
qualified destination and required reads; it must deny writes and other
unnecessary provider operations. Token and certificate identities must also be
separate from recorder/upload identities. The provider's denial checks and
full qualification remain required; Helm cannot verify Secret contents or IAM.

The reader runs one replica with `Recreate` updates through
`ServiceRadarCoreElx.CameraStorage.Service.main_read()`, with empty release
configuration and distribution disabled. Its read-only root filesystem has
only a bounded 32 MiB temporary mount. It receives no CNPG/NATS credentials,
core distribution cookie, recorder spool or Kubernetes API token. The private
`serviceradar-archive-reader` ClusterIP listens on `archiveReader.port` (4444 by
default); set `listener.port` and Web's base URL to the same port. No public
Service port or Gateway route is added.

The reader's NetworkPolicy always limits ingress to Web on the reader port,
and egress to DNS in `kube-system` plus the explicit provider or CONNECT proxy
CIDRs/port. Set `archiveReader.egressProxy` only when a CONNECT proxy is needed.
The chart excludes the reader from its broader Kubernetes and Calico policies,
including custom match-all selectors. When ordinary Kubernetes network
isolation is enabled, its existing egress policy gains the reader destination
and port without expanding the selected workloads. The reader's ingress still
restricts callers to Web. The optional Calico policy has an explicit Web-only
allow rule. No new Web-isolating policy is added, including when an operator's
general policy excludes Web. Policies outside the chart and actual cluster
enforcement still require inspection.

Bump `archiveReader.revision` to coordinate reader and Web rollout after changing
configuration or identity files. The reader loads its installation at startup;
Web reloads its client configuration on each read request. A rollout is not a
readiness handshake. The existing single read slot, ten-second deadline, exact
range/digest checks and final human-authorization/proof check remain unchanged.

This chart wiring does not create a bucket, adopt an allocation, qualify a
provider, start a recording or publish an archive. Production activation still
requires all 19 qualification checks and fresh per-purpose upload authorities
within their at-most-30-second installation windows. A running reader pod alone
does not prove those gates, available archive footage or hosted readiness.
