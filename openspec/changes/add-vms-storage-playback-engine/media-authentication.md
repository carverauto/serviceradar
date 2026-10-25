# Deployment-scoped media authentication

The private control listener uses a separate credential for media operations.
It protects both methods of the [qualification receipt API](qualification-receipts.md),
`GET /v1/media/installation`, both methods of the
[recording stop contract](recording-control.md), and
[private archive registration](archive-registration.md). The account-level password-reset credential
cannot call those routes; the media credential cannot request password resets.
There is no account-token fallback for media.

## Installed identity and request contract

Infrastructure installation supplies a media token, a canonical lowercase
deployment UUID and a positive generation. These identify this runtime process;
they are not tenant selectors, database scope or caller-controlled actor fields.
The token must contain 32 through 512 bytes and differ from the account token.
Missing or invalid installation values leave media authentication closed.

Every media request supplies exactly one of each header:

| Header | Value |
| --- | --- |
| `X-ServiceRadar-Control-Plane-Authorization` | `Bearer <media token>` |
| `X-ServiceRadar-Deployment-Ref` | The exact installed lowercase UUID |
| `X-ServiceRadar-Media-Generation` | The exact installed canonical decimal generation |

Generation is a string from `1` through `9223372036854775807`, without signs,
spaces or leading zeros. It stays a string in Helm values, headers and JSON
responses so intermediate numeric parsers cannot round it. Standard
`Authorization` remains reserved for the Kubernetes API pod proxy. Invalid,
missing, duplicate or mismatched authentication headers return the same bounded
HTTP 401 response before body parsing or receipt storage.

The installation endpoint returns HTTP 200 with `schema_version: 1`,
`status: installed`, the installed `deployment_ref` and string `generation`,
`applied_revision: null`, `readiness: unavailable` and
`reason: media_authentication_only`. It does not echo credential bytes. A caller
must compare the returned identity to its intended installation. This confirms
the responding process's authentication configuration only, not every replica's
rollout, evidence freshness, applied media configuration or provider authority.

## Helm and Cloud ownership

`webNg.controlPlaneRuntime.media` in the [chart values](../../../helm/serviceradar/values.yaml)
is disabled by default. Enabling it requires `deploymentRef`, a quoted
`generation`, and a separate infrastructure Secret referenced by
`existingSecretName` / `tokenSecretKey`. Token bytes never enter chart values.
The three media environment variables cannot be supplied through generic
`extraEnv` or `extraEnvValueFrom` overrides.

Media can enable the existing pod-only listener independently of the
account/password-reset credential. Neither mode exposes that listener through
a public Service or Gateway. The deployment reference and generation are also
pod-template annotations. Changing either replaces pods, which read their
installation at boot. Changing Secret bytes alone is not a rollout or revocation
mechanism: old processes can still accept their old credentials until stopped.
Any future rotation workflow must observe replacement and retirement explicitly.

Cloud owns the environment UUID, persisted generation, purpose-specific token
derivation, Secret installation and ownership-checked pod acknowledgment. Its
[approved plan](https://github.com/carverauto/serviceradar-control/pull/185)
remains the owner of hosted resource provisioning. Community operators can
install the same product authentication contract through infrastructure custody.

## Remaining authority boundary

This authentication cannot promote retained receipts, including receipts made
through the former account-level ingress, into current storage authority. Receipt
rows do not establish authenticated historical origin or freshness. The full
desired/applied content identity, fresh correlated evidence, revocation, isolated
storage credential custody and provider execution remain separate requirements.
No recording, dispatch, provider operation or local-media reclamation follows an
installation acknowledgment.
