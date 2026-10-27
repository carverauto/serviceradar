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
has its own runtime configuration; this chart does not install it.
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
