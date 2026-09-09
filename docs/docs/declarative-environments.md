# Declarative ServiceRadar environments

The ServiceRadar Terraform provider makes supported application configuration
repeatable and reviewable. A team can reuse a module for QA and production, review
the proposed differences, and detect drift when operators change managed resources
through the UI or API. Environment-specific inputs keep endpoints, credential
references, and target scopes distinct.

## Installation, configuration, and execution

[Helm](./helm-configuration.md#deployment-provisioning) installs ServiceRadar on Kubernetes; Argo CD can reconcile that installation.
The ServiceRadar provider configures selected resources through the running
application's public HTTPS API. Ansible executes host changes through playbooks.

The current provider does not install ServiceRadar or AWX, enroll agents, configure
high availability, replicate application data, or orchestrate primary/failover
transitions. It does not launch playbooks or provision upstream AWX objects.

## Bootstrap before application configuration

Use two delivery stages:

1. Install and start ServiceRadar, establish HTTPS access, and create the API
   identity and authorization that the configuration job will use.
2. Configure the provider with that endpoint and credential, then plan and apply
   the supported application resources.

Self-hosted ServiceRadar already supports startup admin bootstrap when no admin
exists. Follow [Bootstrap Admin Access](./auth-configuration.md#bootstrap-admin-access-self-hosted)
for its required password or password-file configuration and normal post-login
account management. An admin login and a Terraform API credential are distinct.

The provider cannot create its own initial ServiceRadar account or API key, and
its endpoint and authentication must be known when Terraform configures it. The
current provider does not automate the handoff from installation/admin bootstrap
to the first authorized API credential. Establish that credential before stage two;
do not treat Terraform's integration-credential resource as an API-login resource.

Supply `SERVICERADAR_ENDPOINT` and exactly one of `SERVICERADAR_API_KEY` or
`SERVICERADAR_API_TOKEN` through protected runtime injection. API keys must be
user-bound; the alternative is an OAuth/access bearer token. Provider arguments
also accept an ephemeral input. Both the account's permissions and the token's
capabilities must authorize each operation. See the
[API permissions](./ansible-provisioning-api.md#authentication-and-permissions).

A secret manager can deliver an existing API credential to a trusted job. Storing
a token in that manager does not create its ServiceRadar principal or grant it
permission. Bootstrap ownership remains a separate deployment responsibility.

## Ordered delivery and verification

An external pipeline can own installation and application configuration as separate
stages with separate states. The installation stage and Terraform runner must be
able to start without a running ServiceRadar. This is not a single-apply bootstrap:
the ServiceRadar provider requires known connection settings before it can plan.

1. Install through the existing Helm/Argo CD workflow and establish HTTPS trust.
2. Wait for application readiness, completed database migrations, and a reachable
   HTTPS API. A ready Kubernetes release alone is not proof of API readiness.
3. Complete the existing admin bootstrap if needed, then separately establish an
   authorized, user-bound API key or bearer identity for the configuration job.
   Verify the permissions described in the provisioning API contract.
4. Build and install the development provider through the Bazel targets in the
   [provider reference](./terraform-provider.md#development-and-verification).
   It is not yet available from the Terraform Registry. Initialize the customer's
   protected backend and provider installation before planning.
5. Import resources already present under their exact UUIDs before trying to
   create them. Assign one state as their owner and review the refreshed plan.
6. Apply the reviewed fresh plan with runtime-injected authentication and ephemeral
   credential inputs. Re-supply those inputs when applying a saved plan.
7. Refresh and confirm a no-change plan. Investigate unexpected drift before
   approving another apply; do not use replacement as a blind retry.
8. Separately verify repository catalog synchronization and controller observations.
   A no-change plan does not prove asynchronous work finished. Membership/binding
   approval and operational playbook launch remain explicit, separate actions.

## What can be declared today

| Resource and data source family | Managed configuration |
| --- | --- |
| `serviceradar_network_credential_secret` | Unified integration credentials and their metadata |
| `serviceradar_network_credential_rule` | Credential scope, purpose, target query, and edge selection |
| `serviceradar_ansible_controller` | Registration of an existing AWX/AAP controller |
| `serviceradar_ansible_repository` | A public Git playbook catalog repository |

Controller registration needs an enrolled agent and valid unified credential
references. Terraform can create an integration credential from supplied material.
Existing upstream AWX projects, inventories, inventory sources, execution
environments, credentials, and templates remain outside this provider, as do
membership approval, template-binding review, and playbook launch.

Repository changes can schedule asynchronous catalog synchronization. An accepted
apply does not prove that synchronization completed or that a playbook is ready.
Inspect the observed status separately. The [provider reference](./terraform-provider.md)
covers resource identity, guarded deletion, imports, and drift handling.

## Keep secret material out of state

Prefer an existing credential's exact UUID when possible. Credential data sources
return metadata and cannot retrieve secret material. For new material, use
`values_wo` and a positive `values_version`; Terraform 1.11 or later is required.
Declare the source input with both protections:

```hcl
variable "integration_token" {
  type      = string
  sensitive = true
  ephemeral = true
}
```

Pass the input to the appropriate field in `values_wo`. The synthetic example in
`terraform/examples/configuration` shows the complete resource. `sensitive` redacts
normal display; `ephemeral` omits the input value from state and saved plans.
Sensitive marking alone is neither encryption nor non-persistence. Do not place material
in literal configuration, descriptions, outputs, or persistent variable files.
The provider's API authentication arguments need the same secure sourcing.

Increase `values_version` for each rotation. Changing only `values_wo` does not
produce a secret comparison or trigger rotation. The version is an operator-owned
counter, not a hash of the material; imported credentials start at zero until an
explicit rotation. Re-inject ephemeral inputs and API authentication when applying
a saved plan. The plan does not retain the secret bytes or prove which material
will be supplied at apply. Coordinate the secret version and rotation counter in
the delivery workflow.

ServiceRadar stores submitted internal credential material encrypted in its
canonical [CNPG credential model](./credentials.md). Terraform reads cannot recover it. Write-only
handling protects the intended material fields, not every attribute.

## Protect shared state and delivery jobs

State still contains names, usernames, controller and repository URLs, target
queries, scope values, resource and credential IDs, public fingerprints, status,
and version information. Treat state, saved plans, and backups as confidential.
Metadata is ordinary stored and planned configuration, not automatically redacted.
Keep environment-specific configuration in customer-private operational repositories;
public product examples must contain only invented values. An ordinary secret-reading
data source can persist its source value even when a downstream argument is
write-only. Use a verified ephemeral retrieval path or protected runner injection.
Other providers, debug logs, and backend behavior have separate leakage contracts.

Use a remote backend with encryption, access controls, auditability, versioning,
and state locking. Protect saved plans, logs, backups, and CI artifacts with
restricted access and retention. Treat runners as privileged: they can read runtime
secrets and change application configuration. Inject secrets only into trusted jobs.
Separate QA and production state, API identities, credentials, and access policies;
workspace naming alone provides no isolation. The backend and recovery automation
must remain available during a ServiceRadar outage. This provider does not
configure or secure the backend. See
[Terraform sensitive-data guidance](https://developer.hashicorp.com/terraform/language/manage-sensitive-data).

Assign one configuration owner to each resource. Review a refreshed plan before
applying changes: the provider sends the server's resource version on updates and
deletes, and stale versions fail. A timeout can follow a successful creation;
retain its idempotency key and reconcile before retrying.

## Disaster recovery and failover

Terraform configuration and state backups do not replace application disaster
recovery. Preserve the relevant application database, NATS durable state, and
recoverable encryption keys through secure backups or replication. Test restoration
and controlled promotion, including access to the secret server, runner, state
backend, and recovery automation while ServiceRadar is unavailable. Terraform does
not implement replication, promotion, enrollment, or runtime backups. Restoring encrypted credential rows
without usable keys does not restore their credentials. After application recovery,
Terraform can refresh and reconcile the resources it manages.

Replicas or failover instances using the same restored database represent one
logical configuration. Use one configuration owner and its current API endpoint,
rather than separate Terraform states independently managing the same IDs. A fresh,
independent environment needs its own bootstrap, secret delivery, and configuration state; applying
a module does not copy runtime data or recover credentials from another environment.

## Future Delinea Secret Server integration

The backend already has an external-reference broker path with OpenBao support
and a Vault alias, with limited consumer coverage. Delinea Secret Server is not
implemented; its adapter name is a placeholder. The current Terraform/public
credential creation path accepts internal encrypted material and has no
secret-provider or external-reference CRUD.

The planned `add-external-secret-provider-broker` work explicitly names Delinea
Secret Server. Distinguish two integrations:

- **Runner credential delivery:** a secret server supplies an already-issued
  ServiceRadar API credential to Terraform. This requires trusted runner/provider
  authentication and existing ServiceRadar principal/RBAC grants. Retrieving a
  token creates neither the principal nor its permissions.
- **ServiceRadar runtime resolution (proposed):** canonical credential inventory
  and rules hold references, with bounded, audited broker grants resolving material
  at use time. The Delinea adapter and declarative provider/reference management
  remain separate follow-up work; this guide adds no resource or endpoint.

[Delinea's Terraform documentation](https://docs.delinea.com/online-help/integrations/terraform/configure.htm)
describes ephemeral retrieval. It is an unverified interoperability option here:
pin compatible provider versions and test with synthetic secrets for leakage before
adopting it. Do not copy static secret-bearing tfvars into operational configuration.

The proposed runtime path needs explicit field/version mapping, rotation semantics,
least-privilege provider authentication, and cache, lease, renewal, revocation, and
outage policies. New provider bootstrap material must use canonical encrypted
integration-credential custody, not new Kubernetes, Helm, or environment stores for
integration secrets. Existing OpenBao bootstrap uses options/environment tokens or
Kubernetes login; this is a legacy limitation, not implemented canonical
`internal_credential` lookup or a recommendation for new adapters.

Consumer migrations, lease/renewal, audit, and UI/API coverage remain partial.
Some legacy scheduled paths still materialize runtime parameters, so the broker
foundation does not mean every plugin already receives only references. Follow-up
acceptance must verify compatibility, rotation, revocation, provider outages,
failover reachability, and absence of material in plans, state, logs, and plugin
configuration. Runner delivery and runtime resolution both retain their own initial
trust and authorization prerequisites.

## Availability and evidence

The provider is implemented but not yet published to the Terraform Registry.
The example assumes a development build installed locally. See the
[provider reference](./terraform-provider.md#development-and-verification) for tests.

Pinned Terraform CLI tests check that ephemeral material and an environment-supplied
API token are absent from output, saved-plan entries, state, and backups against a
synthetic HTTPS API. This covers the tested path, not arbitrary CI/backend settings.

End-to-end installation-to-identity bootstrap, primary/failover recovery, Delinea
compatibility, and the approved signed-artifact canary rollout remain operational
acceptance work. Documentation completion and synthetic provider tests do not prove
those outcomes. Record evidence from the relevant checks before claiming them.
