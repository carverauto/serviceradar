## 1. Specification and documentation reconciliation

- [x] 1.1 Update the pending `add-ansible-integration` proposal, design, UI requirements, and tasks so they no longer prescribe `/ansible/runs*`, `PlaybookRun` launch UI, or a legacy device-history panel.
- [x] 1.2 Update `docs/docs/ansible.md` to describe canonical operation launch/history behavior and remove obsolete route, schedule-result, and permission guidance.
- [x] 1.3 Reconcile the pending `add-northbound-action-integrations` change and directly affected Ansible documentation so they do not prescribe the retired Ansible adapter, bulk raw-`extra_vars` modal, or secondary Ansible Action History.

## 2. Canonical Ansible UI

- [x] 2.1 Wrap catalog, launch, operation index, and operation detail LiveViews in the authenticated operations shell.
- [x] 2.2 Remove the legacy run routes and delete `RunsIndex` and `RunsShow`.
- [x] 2.3 Remove legacy comparison copy and links from operation history components; retain useful authority, target, scope, revision, hold, diagnostic, and dispatch evidence.
- [x] 2.4 Move the launch LiveView's Permit resource to `AutomationOperation` without changing deployed RBAC permission keys.
- [x] 2.5 Remove the fail-closed Schedules and Retention tabs, interactive schedule controls, schedule-evaluator presentation, and controller run-pulse field while preserving backend resources and workers.
- [x] 2.6 Route launch through canonical create authorization, gate its affordances, and independently reauthorize every controller/repository settings event.
- [x] 2.7 Make catalog, launch, and settings disconnected mounts inert and defer data/secret-reference loads until the socket connects.
- [x] 2.8 Split inventory actions into canonical **Launch Playbook** under `ansible.runs.launch` and provider-neutral **Run Action** under `northbound.actions.launch`; never treat either permission as authority for the other path.
- [x] 2.9 Stop operator catalog reads from synchronizing or returning Ansible northbound descriptors, while preserving retained provider/descriptor rows as internal evidence.
- [x] 2.10 Remove the Ansible-specific northbound bulk form, AWX-applicability shim, and raw `extra_vars` escape hatch; keep the constrained schema renderer for non-Ansible providers.

## 3. Device detail cleanup

- [x] 3.1 Remove `PlaybookRunTarget` loading, assigns, refresh handling, and legacy PubSub subscription from the device Ansible runtime.
- [x] 3.2 Render only recent operation history, canonical operation links, and an operation-only empty state while retaining AWX-managed device detection.
- [x] 3.3 Keep generic Action History under `northbound.actions.view`, but exclude retained Ansible-provider invocations so `ansible.runs.view` exposes only canonical operation history.

## 4. Regression coverage

- [x] 4.1 Assert the operations index/detail, launch, and catalog routes render the operations topbar, sidebar, and page title.
- [x] 4.2 Assert the retired `/ansible/runs*` paths do not resolve and no product UI renders a link to them.
- [x] 4.3 Update operation-history and device-panel tests to cover canonical evidence, operation links, the operation-only empty state, filtered Ansible northbound history, and absence of legacy presentation copy.
- [x] 4.4 Assert Ansible settings expose only authorized controller/repository tabs and no schedule, retention, evaluator, or run-pulse controls.
- [x] 4.5 Run focused DB-backed LiveView/component tests and a browser smoke check of the affected authenticated routes.
- [x] 4.6 Cover launch-only, view-only, controller-only, repository-only, Ansible-only, and northbound-only custom-role behavior, including real launch readiness, forged-event denial, cross-resource denial, and exact inventory-action visibility.

## 5. Quality gates

- [x] 5.1 Run `mix format --check-formatted` and `mix precommit` in `elixir/web-ng`.
- [x] 5.2 Run `make lint` and `make test` from the repository root.
