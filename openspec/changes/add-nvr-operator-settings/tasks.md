# Tasks

Stage A is implementable in the order A0, A1, A2. A2 touches files the archive
slice (`feat/nvr-archive-upload`) is still changing; start A2 only after that
slice merges to `staging`. Stage B tasks are blocked on the named
recording-plane tasks and stay unchecked until those land.

## A0. UI-only

- [ ] A0.1 Add RBAC keys `settings.recording.view`, `settings.recording.manage`,
      `settings.recording.operate` (admin default) to
      `ServiceRadar.Identity.RBAC.Catalog`.
- [ ] A0.2 Add parent group `:sys_recording` and view `:camera_recording`
      (`/settings/recording`, tabs `recorders`, `archive`, `cameras`, `policy`,
      `health`, keywords per design D1) to `ServiceRadarWebNGWeb.Settings.Catalog`;
      route in the existing authenticated settings `live_session`.
- [ ] A0.3 New LiveView `ServiceRadarWebNGWeb.Settings.RecordingLive` with
      `supported_tabs/0`; no database reads in disconnected mount; every
      `handle_event` re-authorizes with `RBAC.authorize_current/2`.
- [ ] A0.4 Install and gate banner: Core gate from `:nvr_recovery_gate`
      ("not configured" vs "closed"), core-elx reachability and
      `CameraRecording.Supervisor.enabled?/0` over bounded `:rpc`, each with an
      explicit unavailable state and a docs link.
- [ ] A0.5 Archive tab, read-only: list `ArchiveBinding` generations (endpoint,
      region, bucket, prefix, generation, destination SHA-256, "unqualified"),
      and `s3_compatible` credentials with a link to create one at
      `/settings/networks/credentials`.
- [ ] A0.6 Cameras tab: camera and relay-eligible profile pickers; Stage B tabs
      render a "blocked" panel naming the missing prerequisite.
- [ ] A0.7 Link "Recording & storage" from `/cameras/:id` and
      `/cameras/:id/recordings`; label the existing recordings page's source.
- [ ] A0.8 LiveView tests for each explicit state, permission hiding, deep-link
      denial and Ctrl+K discovery by "camera" (catalog test covers routing).

## A1. Core-only backend

- [ ] A1.1 `ServiceRadar.Camera.RecordingArchiveSettings` singleton with FK
      restrict references (design D6), PaperTrail, AuditHistory allow-list, and
      secret validation (provider `s3_compatible`, kind `opaque`, enabled, not deleted).
- [ ] A1.2 Credential usage loader and consumer link in
      `CredentialUsage.load_direct_consumers/1`; destroy guard in
      `GuardCredentialDestroy`; test that deletion is refused while referenced.
- [ ] A1.3 `ServiceRadar.Camera.NVRArchiveReceipt` append-only resource
      (design D9): identical-bytes idempotency, conflict refusal, no update or destroy.
- [ ] A1.4 `ServiceRadar.Camera.RecordingOperation` with one terminal transition
      and the `effective_state` calculation (`running` past `deadline_at` reads
      `outcome_unknown`).
- [ ] A1.5 `ArchiveDestinations.register_operator/2` (`operator:<name>` refs,
      next generation, field-level errors).
- [ ] A1.6 `ArchiveDestination` schema v2 with operator key prefix in `namespace`;
      version-aware check constraint; resolver grant path unchanged; v1 rows
      unaffected.
- [ ] A1.7 `RecordingBlocks.operator_page/3` keyset projection for one camera.
- [ ] A1.8 Wire the archive tab: create destination, choose active destination,
      select writer and optional reader credential (requires
      `settings.credentials.manage`; redacted name otherwise), archive on/off.

## A2. After the archive slice merges

- [ ] A2.1 NVR endpoints: `GET /v1/status`, `POST /v1/blocks/lookup`,
      `GET /v1/blocks`, `GET /v1/blocks/<id>/archive-receipt`,
      `POST /v1/archive-probe`, `POST /v1/blocks/<id>/verify`,
      `POST /v1/blocks/<id>/archive-verify` (design A2 table), with the
      recovery-gate, read-slot and body-size bounds of the existing listener.
- [ ] A2.2 Matching `ServiceRadarNVRClient` functions; non-200 bodies returned.
- [ ] A2.3 Move readback hashing into `serviceradar_object_storage`; archive,
      probe and archive-verify share it.
- [ ] A2.4 `NVRTargetConfig.members/1`.
- [ ] A2.5 `CameraRecording.Operations` facade under a core-elx `Task.Supervisor`,
      writing `RecordingOperation` and broadcasting progress; no automatic retry
      of uncertain outcomes.
- [ ] A2.6 Persist `NVRArchiveReceipt` from `NVRArchive.archive_block`; add
      `receipt_import` with unmatched-receipt reporting.
- [ ] A2.7 Recorders tab: members, storage IDs, readiness, per-member gate,
      capacity, archive slot busy; "unknown" for unreachable members.
- [ ] A2.8 Destination test action per member (design D12).
- [ ] A2.9 Cameras tab actions: bounded capture (member, profile, duration
      1..300 s), archive a sealed block to the active destination, local and
      archive retrieval checks, operation history.
- [ ] A2.10 Per-camera block list with streams and the location table of design
      D10, including receipt details (objects, keys, lengths, SHA-256, ETag,
      verified at).
- [ ] A2.11 Tests through real boundaries: NVR endpoint release tests with
      synthetic media (invented hosts such as `objects.example.com`, bucket
      `example-archive`); core-elx facade against a test NVR; LiveView tests for
      unknown-versus-absent and uncertain outcomes.

## Docs

- [ ] D.1 Published operator page `docs/docs/camera-recording.md`: enabling,
      the settings view, destination and credential setup, tests and checks,
      what each state means, what Stage A does not do (no reclamation, local
      disk grows until capacity refuses capture).
- [ ] D.2 Update `docs/docs/credentials.md` (camera archive consumer) and
      `docs/docs/rbac-and-roles.md` (three keys); cross-link `docs/nvr-runtime.md`.

## Stage B (blocked)

- [ ] B.1 BLOCKED on recording-plane 2.2, 2.4, 2.5: `CameraRecordingPolicy`
      resource and policy tab (design D13).
- [ ] B.2 BLOCKED on 3.2, 3.4: automatic archive of every sealed block to the
      active destination when `archive_enabled`.
- [ ] B.3 BLOCKED on 3.4, VMS holds/exports (and 3.3 for local-only):
      `hot_retention_seconds` (code default 86 400) and reclamation status.
- [ ] B.4 BLOCKED on 3.2, 3.5: backlog and archive health via JetStream telemetry
      and the health tab.
- [ ] B.5 BLOCKED on 3.3, 3.7 and VMS catalog publication of NVR archives:
      forced-source playback (`source=local|archive`) in the existing player.

## Validation

- [ ] V.1 `openspec validate add-nvr-operator-settings --strict`.
- [ ] V.2 `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix --lint-only`
      and the core equivalent; targeted tests; no lint suppressions.
- [ ] V.3 Manual walk-through on a disposable install: NVR absent, gate closed,
      gate open, destination created, test passed, capture, archive, both
      retrieval checks, credential deletion refused.
