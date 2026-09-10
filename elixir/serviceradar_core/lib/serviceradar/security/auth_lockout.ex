defmodule ServiceRadar.Security.AuthLockout do
  @moduledoc """
  Account-level lockout. Created when failed-login events for an actor
  exceed a threshold across any combination of source IPs within a
  rolling 1-hour window. Subsequent auth attempts for that actor are
  short-circuited by `ServiceRadarWebNGWeb.Plugs.LockoutCheck` with a
  generic "account temporarily locked" message — no information leak
  about the lockout reason.

  Unlock requires the `:security_admin` capability. Lockouts may also
  expire automatically when `expires_at` is set and reached.
  """

  use Ash.Resource,
    domain: ServiceRadar.Security,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "auth_lockouts"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index [:actor_id]
      index [:cleared_at]
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "auth_lockout_versions"
    mixin {ServiceRadar.Security.PaperTrailMixin, :mixin_with_audit_actor, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :list, action: :read
    define :get_active_for, action: :active_for, args: [:actor_id]
    define :lock_actor, action: :lock
    define :unlock, action: :unlock
  end

  actions do
    defaults [:read]

    create :lock do
      primary? true
      accept [:actor_id, :reason, :locked_by, :expires_at]

      change set_attribute(:locked_at, &DateTime.utc_now/0)
    end

    update :unlock do
      accept [:cleared_by, :clear_reason]
      change set_attribute(:cleared_at, &DateTime.utc_now/0)
    end

    read :active_for do
      argument :actor_id, :string, allow_nil?: false
      get? true

      filter expr(
               actor_id == ^arg(:actor_id) and is_nil(cleared_at) and
                 (is_nil(expires_at) or expires_at > now())
             )
    end
  end

  policies do
    import ServiceRadar.Policies

    alias ServiceRadar.Policies.Checks.ActorHasPermission

    @audit_view {ActorHasPermission, permission: "settings.audit.view"}
    @audit_manage {ActorHasPermission, permission: "settings.audit.manage"}

    system_bypass()

    action_type_with_permission(:read, @audit_view)
    action_type_with_permission([:create, :update, :destroy], @audit_manage)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :actor_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 128
    end

    # Note: :utc_datetime (seconds precision), not :utc_datetime_usec.
    # AshPaperTrail 0.5.7's notification-build path crashes when version
    # records carry microsecond-precision datetime attributes ("expects
    # microseconds to be empty"). Seconds precision is sufficient for
    # lockout timestamps. The DB column accepts timestamptz either way.
    attribute :locked_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :locked_by, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :reason, :string do
      allow_nil? true
      public? true
      constraints max_length: 256
    end

    attribute :expires_at, :utc_datetime do
      allow_nil? true
      public? true
    end

    attribute :cleared_at, :utc_datetime do
      allow_nil? true
      public? true
    end

    attribute :cleared_by, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :clear_reason, :string do
      allow_nil? true
      public? true
      constraints max_length: 256
    end

    timestamps()
  end
end
