# ServiceRadar Terraform provider

The first-party Go provider configures ServiceRadar through its public HTTPS API.
The current resource and data source families are:

| Terraform type | Public API collection |
| --- | --- |
| `serviceradar_network_credential_secret` | `/api/admin/network-credential-secrets` |
| `serviceradar_network_credential_rule` | `/api/admin/network-credential-rules` |
| `serviceradar_ansible_controller` | `/api/admin/ansible-controllers` |
| `serviceradar_ansible_repository` | `/api/admin/ansible-repositories` |

This initial provider does not provision upstream AWX objects, approve inventory
membership or template bindings, or launch playbooks. Repository creation and
updates may schedule the server's normal catalog synchronization. Its observed
`last_sync_status` is an output; an accepted configuration is not proof that catalog
synchronization completed. The broader declarative provisioning API remains
tracked in `add-declarative-ansible-provisioning`.

## Authentication and trust

Set `SERVICERADAR_ENDPOINT` to the ServiceRadar HTTPS origin and
`SERVICERADAR_API_KEY` to a user-bound API key. Alternatively, set
`SERVICERADAR_API_TOKEN` to an OAuth/access bearer token. Configure exactly one:
API keys use `X-API-Key`, while bearer tokens use `Authorization`. The matching
provider arguments are `api_key` and `api_token`. The account and token
must both authorize the requested operation. Legacy static tokens without an
account are not suitable. Credential resources require
`settings.credentials.manage`; controller and repository resources require
`ansible.controllers.manage` and `ansible.repositories.manage`, respectively.
Repository refresh and data sources also require `ansible.catalog.view`.

The provider verifies TLS using the system trust store. The optional
`ca_certificate` provider argument adds a PEM CA certificate. HTTP origins,
URL credentials, endpoint paths, and redirects are rejected. The provider
does not print request bodies, response bodies, authorization headers, or raw
transport errors in diagnostics.

## Credentials without material in state

Use an existing credential's exact UUID whenever possible. The matching data
source reads only public metadata. Terraform calls the API's `provider` field
`credential_provider` because `provider` is reserved in Terraform resources.

New credential material uses the `values_wo` map, with a positive
`values_version`. This requires Terraform 1.11 or later. Declare the source
variable `ephemeral = true` and `sensitive = true`; marking an ordinary resource
argument sensitive would not keep it out of state. Do not put credentials in
literal configuration, metadata, outputs, or persistent variable files.

Increase `values_version` to rotate the material. Changing `values_wo` alone
does not produce a plan or trigger rotation. The version is an operator-supplied
counter, not a digest of the secret. Imports use version zero until an explicit
rotation is requested. Reads never recover material from ServiceRadar.

## Identity, refresh, and deletion

Each create needs a unique, stable UUID in `idempotency_key`. Retain this value
after a timeout and reconcile the same request. Do not change the key to force
a retry: the previous create may already have succeeded. Imports may omit this
create-only identity. A provider error preserves the server's deletion guard;
disabling a resource is separate from deleting it.

Changing a credential's provider or authentication method requires replacement.
Supply an explicitly known, fresh `idempotency_key` and write-only credential
material in that replacement plan. Reusing the previous creation key is rejected
before Terraform can delete the existing credential; deletion remains subject to
the server's usage guard.

Import with the exact ServiceRadar UUID, for example:

```text
terraform import serviceradar_ansible_controller.example 11111111-2222-4333-8444-555555555555
```

Refresh reads canonical server values, including an opaque `etag`. Updates and
deletes send that version with `If-Match`. A stale version is rejected, so
refresh and review a new plan before retrying. Optional computed arguments
retain the server's value when omitted; omission does not request deletion of
that field. Required provider/authentication-method changes replace a
credential, subject to its guarded deletion.

## Development and verification

The provider is implemented in `go/pkg/terraformprovider`, with its protocol
server in `go/cmd/terraform-provider-serviceradar`. It is not yet published to
the Terraform Registry. Build and test it through the corresponding Bazel
targets. The example under `terraform/examples/configuration` is synthetic and
assumes this development provider is installed using Terraform's normal local
provider installation mechanism.

The Go tests drive the actual Plugin Framework protocol against an invented
HTTPS API: create, idempotent replay, refresh, import, a no-op second plan,
out-of-band drift, update, guarded deletion, and missing-resource refresh.
They inspect state for write-only material and cover a successful rotation
followed by a failed metadata update.

The separate CLI acceptance target runs pinned Terraform 1.11.4 with the provider
binary as a declared Bazel input. It installs from a local filesystem mirror,
then verifies saved plan/apply, a no-op plan, drift repair, credential rotation,
import, guarded destroy, and successful destroy against the HTTPS fixture.
Credential material must be absent from command output, saved plan archive
entries, state, and state backups. Both test suites use synthetic fixtures;
live API compatibility is covered separately by the database integration lane.

```text
bazel test --config=remote //go/pkg/terraformprovider:terraformprovider_test //go/pkg/terraformprovider:terraform_cli_acceptance_test
```
