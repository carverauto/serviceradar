defmodule ServiceRadar.Observability.ApiEvent do
  @moduledoc """
  Centralized AshEvents event log for API-first Observability resources.

  This is a single, shared `AshEvents.EventLog` -- not one event log per
  resource. Every resource opted into auditing via `AshEvents.Events`
  (currently only `ServiceRadar.Observability.StatefulAlertRule`) records
  its create/update/destroy actions here, keyed by actor, so "what did this
  actor do, across everything, in order" is answerable from one table.

  See `openspec/changes/add-ash-events-audit-log/design.md#decisions` for
  the adoption boundary: AshEvents is for new API-first *mutable* resources;
  existing resources keep their `AshPaperTrail` version history. Do not add
  a resource here without reading that boundary first.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.EventLog],
    # The primary `:read` action's `build(sort: ...)` preparation is
    # intentional (default chronological order for the audit UI), not the
    # mistake this warning usually flags.
    primary_read_warning?: false

  postgres do
    table "api_events"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index [:occurred_at], using: "BRIN"
      index [:resource, :occurred_at]
      index [:user_id, :occurred_at]
    end
  end

  event_log do
    clear_records_for_replay(ServiceRadar.Observability.ApiEvent.ClearForReplay)
    primary_key_type Ash.Type.UUIDv7
    record_id_type(:uuid)
    persist_actor_primary_key(:user_id, ServiceRadar.Identity.User)
  end

  code_interface do
    define :list, action: :read
  end

  actions do
    read :read do
      primary? true
      prepare build(sort: [occurred_at: :desc])
    end
  end

  policies do
    import ServiceRadar.Policies

    alias ServiceRadar.Policies.Checks.ActorHasPermission

    @audit_view {ActorHasPermission, permission: "settings.audit.view"}
    @audit_manage {ActorHasPermission, permission: "settings.audit.manage"}

    system_bypass()

    action_type_with_permission(:read, @audit_view)
    # Events are written internally by AshEvents with `authorize?: false`
    # (see `AshEvents.Events.ActionWrapperHelpers.create_event!/5`), so this
    # never gates the write path -- defense in depth only, matching
    # `ServiceRadar.Security.SecurityEvent`'s shape for the same reason.
    action_type_with_permission([:create, :update, :destroy], @audit_manage)
  end
end
