# Existing defects found while writing this proposal

These are defects or operability gaps in behaviour that already ships. They are not the
new capability, and most can be fixed without it. They are listed here so they can be
filed and fixed on their own; the proposal's requirements cover the ones that need a
contract.

`A/` is `elixir/serviceradar_core/lib/serviceradar/automation/ansible/`; `W/` is
`elixir/web-ng/lib/`. "Verified" means the lines were read for this proposal. "Reported"
means a code survey found it and the fixer must re-read before acting. No live system was
inspected.

## Why a host in ServiceRadar is not launchable

| # | Defect | Pointers | Status |
| --- | --- | --- | --- |
| 1 | **Quarantine has no exit.** A quarantined membership stays quarantined on every later observation, including after the ambiguity that caused it is resolved; approval accepts only `proposed`; no action releases a row. Permanence is intended for the approval (an approved requirement: a later match must not inherit it) but not for the row: the operator has nothing to act on. | `A/awx_membership_reconciler.ex:433`, `:462`; `A/changes/approve_awx_host_membership.ex:76`; `openspec/changes/harden-ansible-awx-targeting/specs/ansible-awx-targeting/spec.md:18` | Verified. Addressed by `add-awx-membership-quarantine-release` (recorded reason and human release). |
| 2 | **A host that briefly leaves a sync loses its approval for good.** Expiry clears `current` and `enabled` and leaves the disposition `approved`; when the host is seen again, "approved but not current" is quarantined. Combined with #1 the membership is unusable from then on. | `A/awx_host_membership.ex:151`; `A/awx_membership_reconciler.ex:436` | Verified. **Needs an owner decision** before any fix: whether a host that reappears after expiry requires re-approval. Restoring `approved` on reappearance hands the old approval to a later observation, which the quarantine rule forbids; leaving it quarantined is the defect. The quarantine release of `add-awx-membership-quarantine-release` gives it an exit to `proposed`, and records it as `approved_membership_not_current`, but does not decide the policy. |
| 3 | **The collector drops hosts without an anchor silently, and does not mark the snapshot incomplete.** A host with no address, MAC or hypervisor anchor is skipped with `continue`. If it had a membership, the complete snapshot expires it (then #2). If it never had one, the host is simply invisible: nothing says AWX has a host ServiceRadar ignored. | `go/cmd/wasm-plugins/awx/main.go:3856` | Verified. |
| 4 | **A membership with no address can be approved and can never launch.** Approval does not look at `ansible_host`; the launch resolver's readiness predicate does not either; live preflight then fails on it. | `A/changes/approve_awx_host_membership.ex:71`; `A/awx_membership_approval.ex:215`; `A/secure_launch_resolver.ex:224`; `A/live_awx_launch_preflight.ex:414` | Verified (resolver and preflight); approval path reported. |
| 5 | **The failure in #4 has no message.** `:invalid_awx_preflight_membership` falls through to the generic "current approval or authorization could not be verified". | `W/serviceradar_web_ng_web/live/device_live/ansible_panel_runtime.ex:403` | Verified (fallback line); mapping absence reported. |
| 6 | **"Not ready" does not say why.** Every unready target gets one sentence regardless of cause (never synced, proposed, quarantined, disabled, not current). | `A/secure_launch_resolver.ex:208`; `W/serviceradar_web_ng_web/live/device_live/ansible_panel_runtime.ex:328` | Verified. |
| 7 | **Memberships cannot be found by device, and non-current rows cannot be listed.** The only listing takes exactly a controller and an inventory and returns current rows. | `W/serviceradar_web_ng/ansible_automation.ex:62` | Verified. |
| 8 | **The evidence that explains a quarantine is removed from the API response.** The membership view keeps six evidence keys; the deleted-device marker and the approval record are not among them. | `W/serviceradar_web_ng/ansible_automation.ex:118` | Verified. |
| 9 | **Membership approval has no page.** It exists only as an API call, so memberships sit in `proposed` on any deployment that does not script it. Documentation still describes a "needs review" list as a future feature. | `W/serviceradar_web_ng_web/live/settings/ansible_live.ex:34`; `docs/docs/ansible.md:279` | Verified. |
| 10 | **A device in two inventories may not be linkable in both.** Links resolve through a single `metadata["awx"]` entry per device, so only the inventory currently stamped there can be proposed; if the stamp alternates, one row is quarantined beside a proposed one. This contradicts the approved scenario "Device has multiple AWX memberships". | `A/awx_membership_reconciler.ex:120` | Inferred from the code's shape; needs a reproducing test. |
| 11 | **The same AWX instance can be registered twice**, duplicating every membership: controllers are unique by name only. | `A/controller.ex:373` | Verified (identity); consequence inferred. |
| 12 | **Stale membership rows accumulate and cannot be hidden or removed**; there is no destroy action and execution targets hold a restricting reference. Keeping history is right; showing it as if it were current is not. | `A/automation_execution_target.ex:52` | Reported. A read-model and UI matter. |

How these produce the reported symptoms, as far as code alone can say: rows stay
`proposed` because of #9; a `quarantined` row appears beside a `proposed` one through #2
or #10 and never leaves because of #1; a membership has no address when the host is
anchored by something other than an address (#4); a host is "absent" when it is not in
any synced inventory or was skipped by #3.

## Adjacent defects

| # | Defect | Pointers | Status |
| --- | --- | --- | --- |
| 13 | The catalog's "launchable" filter means "has a template id", not "has a current approved binding", so it lists entries that cannot launch. | `W/serviceradar_web_ng_web/live/ansible_live/catalog_index.ex:266` | Verified. |
| 14 | Approving a binding and approving a membership write no audit event. Revocation does. | `A/awx_binding_review.ex:303`, `:334` | Reported. |
| 15 | The `quarantine_link` action is defined and has no caller. | `A/awx_host_membership.ex:158` | Verified by search. Removed by `add-awx-membership-quarantine-release`. |
| 16 | Binding review may not compare the caller's `input_schema` with the live survey. | `A/awx_launch_contract.ex:1075` | Reported; not verified. Moot for automations, whose schema is server-supplied, but relevant to hand-built templates. |
| 17 | Documentation calls the agent package content an "agent role"; the public repository has root playbooks and task files. | `docs/docs/agent-platform-packages.md:46` | Verified against the repository's `main` branch. |
| 18 | `openspec/changes/add-ansible-integration/tasks.md` has every box unticked although much of it ships, so it cannot be used to tell what is built. | that file | Reported. |
