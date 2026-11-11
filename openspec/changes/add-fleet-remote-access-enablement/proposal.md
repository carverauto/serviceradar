# Change: Enable SSH certificate access and the Proxmox console across an inventory, programmatically

## Why

SSH certificate access works today on the few hosts someone configured by hand. The bar
set by the product owner is that it "must work for every OSS user, not be a huge hassle,
be deterministic and programmatic". Read from the code at `origin/staging` on 2026-11-10
(sources in `design.md`), the present state is:

- **The certificate policy is not product data.** It is a JSON document read once at
  web-ng boot from an environment variable or a file mounted from a Kubernetes Secret.
  No UI, API or Terraform resource can change it, and a change needs a restart. The
  console tells operators to "grant this device a certificate-policy account", which
  no product surface can do. A hosted deployment cannot set it at all, because tenant
  chart values are rendered by a control plane.
- **Policy keys are not identities.** A `targets` key is tried as device UID, then
  hostname, then IP. Hostnames and private addresses repeat across sites, so one key
  grants every device that shares the name.
- **There is no source of truth for principals.** The opaque principal is typed by hand
  into the policy, into each host's principals file and, for callback enrollment, into
  a response-policy file capped at 100 targets.
- **Three on-host layouts exist** (two public Ansible roles and the product
  documentation), and the newer role rejects hosts enrolled by the older one or by hand.
- **ServiceRadar does not know whether a host is enrolled.** The console offers Connect
  and fails with a raw handshake string.
- **Host-key trust is per agent.** Each agent keeps a local known-hosts file; the
  Settings host-key store is a separate review list that verification does not consult.
- **Proxmox console rules** must match the PVE host device, are filtered by the host
  device's owning agent, are checked against a 5,000-row sample, and report every
  refusal as one sentence. Installing an agent on a PVE node silently breaks every
  console under a rule scoped to the API-polling agent.

## What Changes

- **Certificate access becomes runtime-managed credential rules.** A grant is a
  `network_credential_rules` row (provider `ssh`, auth method `ssh_certificate`,
  purpose `remote_access`) with a target query, an edge scope, an actor-use policy,
  Unix accounts and a lifetime. It is managed in Settings, the admin API and the
  existing Terraform resource, takes effect without a restart, is versioned and audited.
  Devices are matched by canonical identity only, by an exact test, never by hostname or
  IP keys and never from a sample.
- **The user CA becomes a managed credential** that rules reference and that an
  administrator can create from Settings, so enabling certificate access needs no
  deployment change.
- **ServiceRadar generates and owns principals**, one per device account (device plus
  Unix account), with rotation and revocation. Certificate issuance and host enrollment
  both derive from that one set.
- **One enrollment bundle per device, one on-host layout, three channels** (AWX
  integrated, direct Ansible with an inventory plugin, manual). Per-host values come
  only from ServiceRadar. The public content keeps one role, which adopts hosts enrolled
  by the older role or by hand, can create a dedicated locked account, and can enroll
  hypervisors under explicit opt-in.
- **Per-device-account readiness** (`not_enrolled`, `pending`, `verified`, `drifted`,
  `unreachable`, each with a reason and a remedy), verified by a certificate
  authenticated no-op probe from the routing agent and shown before Connect. Raw
  handshake strings are replaced by classified failures.
- **Central host-key trust** keyed by device identity, populated by enrollment,
  delivered to whichever agent routes the session, with authorized rotation and
  classified mismatch handling.
- **Identity:** SSO stays the default requirement for certificate mode; a runtime
  setting lets a deployment without an identity provider issue certificates to locally
  authenticated users.
- **Proxmox console:** rule coverage from the stored guest-to-host-to-controller
  relationship by exact test; scope evaluated against the agent that reaches the PVE
  API; a documented minimal privilege set with a verification check; classified denial
  reasons; console readiness per device.
- **Migration:** the file-based policy is imported once into rules and then ignored;
  its chart value is removed in the following release. Existing on-host layouts are
  adopted. **BREAKING** for deployments that keep `remoteAccess.sshCertificatePolicy`
  set after the removal release: the chart refuses to render until the value is deleted.
- **`defects.md`** lists plain bugs that can be fixed before any of this.

## Why a new change and not more requirements in an existing one

`publish-ssh-ca-ansible-enrollment` publishes Ansible content and names remote-access
readiness as a follow-on. `add-automation-callback-grants` and
`harden-ansible-awx-targeting` define how an AWX job is launched and how it reads a
bundle. `add-declarative-ansible-provisioning` and `add-awx-playbook-provisioning`
define how AWX objects are configured. None of them owns the policy data, the
principals, the readiness state or host-key trust, which is what makes enrollment
derivable instead of hand-fed.

## Related active changes

- `publish-ssh-ca-ansible-enrollment`: owns the role and its transaction. This change
  adds requirements to the same capability and relaxes three of its statements
  (`design.md`, "Approved statements this change relaxes").
- `add-automation-callback-grants`: owns the callback grant and the
  `remote_access.ssh_ca.bundle.read` action. This change supplies the response policy
  from stored bundles instead of a file and adds no callback action.
- `harden-ansible-awx-targeting`: owns AWX targeting by membership tuple, the per-child
  target limit and target holds. Nothing of it is relaxed.
- `add-declarative-ansible-provisioning`, `add-awx-playbook-provisioning`: own
  controller, repository and automation configuration. The integrated channel uses
  them and adds nothing to them.
- `harden-proxmox-console-credential-custody`, `add-proxmox-native-guest-terminal-console`:
  own console credential custody, exact owner routing and the terminal adapter. This
  change alters only how a console rule's coverage and scope are computed and how
  refusals and readiness are reported.
- `refactor-unified-credential-management`: owns the credential settings area, usage
  inventory and guarded deletion that access rules and CA records live in.
- `harden-remote-access-security`: its custody, re-authorization and audit contracts
  apply unchanged. The readiness probe is a material credential-mode extension and
  takes that change's review gate.

## Impact

- Affected specs: `remote-access-ssh-certificates` (new), `remote-access-ssh-enrollment`
  (new), `remote-access-host-keys` (new), `proxmox-console-access`,
  `ansible-remote-access-enrollment`.
- Affected code (when implemented): `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_*`,
  `.../credentials/network_credential_rule*.ex`, `.../edge/proxmox_console_sessions.ex`,
  `.../inventory/identity/reassignments.ex`,
  `.../automation/ansible/*callback_response_policy*`, `go/pkg/agent/remoteaccess/`,
  `elixir/web-ng` Settings and device surfaces, `go/pkg/terraformprovider`,
  `helm/serviceradar` (value removal), `docs/docs/remote-access.md`,
  `docs/docs/proxmox.md`, and the public `serviceradar-ansible` repository.
- No product code is changed by this proposal.
