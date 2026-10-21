## Context

`ServiceRadar.Inventory.SourceFacts.Reconciler` stores one row per device,
source, source instance and fact key in `platform.device_source_facts`. It
decides a canonical value with `SourceFacts.decide/3` and keeps
`platform.source_fact_disagreements` in step. Its only producer is the sync
ingestor. That producer replaces everything a source knows about a device in
one update, and keys the update omits are marked absent.

Operator authority rows come from the integration-source form (`source` is the
integration type, `source_instance` its id) and from the plugin assignment form
(`source` is the provider, `source_instance` the plugin instance, which may be
empty). An authority row with an empty instance matches every instance of its
source.

## Goals / Non-Goals

- Goals:
  - An external caller can report and withdraw `switch_port_attachment` and
    `vlan_uid` for a device and take part in comparison, promotion and
    disagreement detection unchanged.
  - A caller cannot impersonate a built-in integration or plugin, and cannot
    touch another caller's facts.
- Non-Goals:
  - A settings surface for making an API source authoritative.
  - Fact expiry, and a batch endpoint.
  - Changing how sync-reported facts are reconciled.

## Decisions

- Decision: A dedicated endpoint, not the scalar facts API.
  - `PATCH /api/devices/:uid/metadata` writes caller metadata for composite
    checks and reserves `switch_port_attachment` on purpose. Source facts are
    inventory evidence with per-source history, so they get their own resource
    path and permission.

- Decision: Store API-reported facts under `api:<label>`.
  - The label is the caller's choice (`^[a-z][a-z0-9_-]{0,62}$`). Sync sources
    are integration types and plugin ids, which never contain `:`.
  - The prefix means a caller labelled `armis` cannot match the Armis authority
    row, cannot match a plugin-assignment row whose instance is empty, and does
    not show up as Armis in a disagreement.
  - Alternatives: reject labels that collide with known sources. Rejected,
    because plugin sources are open-ended and a later plugin could adopt a label
    already in use.

- Decision: The source instance is the caller, derived on the server.
  - `user:<id>` for the user that a session, API token or OAuth client acts for.
    The action derives it from the actor rather than accepting it as input. A
    caller therefore cannot overwrite or withdraw another caller's value, even
    under the same label.
  - On the `/api` pipeline an OAuth client-credentials token resolves to its
    owning user, and the client id is not available to the controller. Two
    clients of one owner share an instance. Different tools are expected to use
    different labels.

- Decision: A report touches only the key it names.
  - `Reconciler.report/5` upserts one row and reconciles. It does not mark the
    caller's other keys absent, unlike `ingest_resolved/2`.

- Decision: Withdrawing an unsupported canonical value clears it.
  - `decide/3` returns `:noop` when no source is present, and the canonical
    value is kept. That suits a sync source that skipped a snapshot.
  - A withdrawal is an explicit statement that the value is gone. After
    reconciling, `Reconciler.retract/5` clears the canonical column when two
    things hold: its compare hash equals the withdrawn value's, and no present
    fact carries that hash.
  - Sync-path behaviour is unchanged.

- Decision: Reject unreadable values.
  - The sync path silently drops a value it cannot parse. The API returns 422
    with the reason instead. That covers a missing hostname or port, a VLAN id
    outside 1-4094, an oversized field (255 bytes, 512 for `raw`), an unknown
    fact key, and an invalid label.

- Decision: Authorization is a generic Ash action on `Device` with its own
  permission.
  - `devices.source_facts.write` gates `:report_source_fact` and
    `:retract_source_fact`, in the same way that `devices.facts.write` gates
    `:write_facts`.
  - A reported switch port can become the canonical attachment, which is why it
    gets a separate grant.
  - The controller resolves the device with the caller's scope, so
    `devices.view` is also required.
  - The action also refuses a deleted device.

## Risks / Trade-offs

- A caller that never withdraws leaves its fact present indefinitely.
  Mitigation: the docs tell callers to withdraw what they can no longer observe.
  Expiry is a follow-up.
- The reconcile runs synchronously in the request, as the sync path runs it in
  the ingest. Concurrent reconciles of one device by the API and a sync batch
  can still race on the open-disagreement row. Nothing makes that row unique
  today, on either path. This change does not alter that.
- API sources cannot be made authoritative, so when an API source disagrees with
  an integration, the canonical value is held, or the integration wins when it
  is authoritative. That is the conservative default.

## Migration Plan

None. The table already accepts any source and instance. Rolling back removes
the routes and actions. Rows written under `api:*` sources can be marked absent,
or deleted by source.
