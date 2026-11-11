# Change: Review AWX memberships and template bindings in the settings UI

## Why

The two human review steps of the AWX integration exist only as JSON routes under
`/api/admin`: approving an inventory membership and preparing, creating, or revoking a
job-template binding. Those routes require a human principal and reject any token
associated with an OAuth client. The only credential the product UI issues is an
OAuth client, and CLI device-login tokens do not reach the configuration API, so an
administrator can list memberships but cannot approve one or bind a template. The
canonical launch flow depends on both steps, so the integration cannot be driven end
to end from the browser. The operator guide already promises a "needs review" list in
**Settings -> Ansible** that is not rendered.

## What Changes

- Add a **Memberships** tab to `/settings/ansible`. Per controller and AWX inventory
  it lists current memberships with host name, address, AWX host ID, link
  disposition, enabled state, the proposed canonical device (linked to its device
  page), link-evidence kind and match count, and last-seen time. A **Needs review**
  filter and per-inventory counts make pending proposals discoverable.
- Approving a proposal opens a review panel that shows the complete evidence tuple
  (controller, inventory, AWX host ID, device UID, source generation, fingerprint,
  evidence digest) and submits exactly that tuple. A proposal that changed in the
  meantime is refused by the domain, reloaded, and shown again; it is never
  re-submitted automatically. Unlinked, quarantined, disabled, and ambiguous
  memberships show why they cannot be approved. There is no way to force a link.
- Add a **Template bindings** tab. Per controller and job template it lists binding
  versions with state, expiry, inventory policy, project and revision, content hash,
  and modes. A two-phase review mirrors the API: the operator enters the request, the
  page shows the broker-observed review returned by prepare and its digest, and only
  then offers **Create**, which submits the same request with
  `expected_review_digest`. A changed review is prepared again and shown; nothing is
  created. Revoking a version uses the typed-confirmation pattern of the credentials
  page.
- Reduce typing where the product already knows the answer: approved memberships are
  chosen from a list, and the template, project, and inventory IDs are suggested from
  AWX-sourced catalog rows. No new brokered AWX read and no provisioning is added;
  content SHA-256 and the review ticket are labeled as values the reviewer attests.
- The UI calls the same `ServiceRadarWebNG.AnsibleAutomation` entry points as the API
  with the session user's scope. Every event re-checks `ansible.controllers.manage`
  from current persisted authority before calling them, and the domain services keep
  their own human-principal and authority checks. The API's OAuth-client rejection is
  unchanged and no token type is added.
- Amend the pending `remove-legacy-ansible-ui` requirement that limits Ansible
  settings to controller and repository management so it also admits this review.

## Impact

- Affected specs: `ansible-integration` (added requirements); pending
  `remove-legacy-ansible-ui` `build-web-ui` delta (one sentence amended).
- Affected code: `elixir/web-ng` Ansible settings LiveView and new review modules,
  `ServiceRadarWebNG.AnsibleAutomation` (two scoped read helpers for the pickers), the
  settings catalog, and LiveView tests.
- Affected docs: `docs/docs/ansible.md`, `docs/docs/ansible-provisioning-api.md`.
- No schema, permission, or API contract change.

## Related active changes

- `add-awx-playbook-provisioning` proposes a broader membership review page (listing
  by device, non-current rows, quarantine release) and binding renewal from an
  automation. This change delivers the approve-and-bind subset in settings and does
  not contradict that scope; that change can extend these tabs. Its task 1.3 amends the
  same `remove-legacy-ansible-ui` sentence for automations and should build on the
  wording this change leaves.
- `add-ansible-integration` describes a `/settings/ansible` "needs review" list for
  AWX hosts DIRE cannot match. Such hosts are the `unlinked` memberships this tab lists
  with their reason; this change does not alter that requirement.
- `harden-ansible-awx-targeting` and `add-declarative-ansible-provisioning` own the
  membership, binding, and API contracts this UI consumes unchanged.
