defmodule ServiceRadar.Identity.CliSession do
  @moduledoc """
  CLI session metadata for JWTs issued through the device-code flow.

  When the token endpoint flips a `DeviceAuthorization` row to `:approved`
  and mints a Guardian JWT, we persist a `CliSession` row keyed on the
  JWT's `jti`. The Settings → CLI sessions page reads from here, and the
  revoke action writes a row into `ServiceRadar.Identity.RevokedToken` so
  the existing `ApiAuth` plug rejects subsequent requests bearing that JWT.

  We deliberately keep this resource separate from `DeviceAuthorization`:
  - device authorizations are short-lived (15 min) and we want to prune them
    aggressively;
  - sessions are long-lived (default 30 d, configurable via
    `AuthorizationSettings.cli_session_ttl_days`) and outlive the device
    flow that minted them.

  Status transitions:

      :active  -> :revoked   (user/admin clicks Revoke; row in token_revocations)
      :active  -> :expired   (cleanup job after JWT expires_at elapses)
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @valid_statuses [:active, :revoked, :expired]

  postgres do
    table "cli_sessions"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :create, args: [:attrs]
    define :get_by_jti, action: :by_jti, args: [:jti]
    define :list_active_by_user, action: :active_by_user, args: [:user_id]
    define :list_active, action: :active
    define :list_all, action: :read
    define :revoke, args: [:revoked_by]
    define :record_use, args: []
    define :mark_expired, args: []
  end

  actions do
    defaults [:read]

    read :by_jti do
      argument :jti, :string, allow_nil?: false
      get? true
      filter expr(jti == ^arg(:jti))
    end

    read :active_by_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id) and status == :active)
    end

    read :active do
      filter expr(status == :active)
    end

    read :expired_active do
      description "Active rows whose JWT TTL has elapsed (cleanup target)"
      filter expr(status == :active and expires_at <= now())
    end

    create :create do
      description "Persist a CLI session — called from the token endpoint after a successful approve"

      accept [
        :jti,
        :device_authorization_id,
        :user_id,
        :client_id,
        :scope,
        :expires_at,
        :issued_at
      ]

      argument :attrs, :map, allow_nil?: false

      change fn changeset, _context ->
        attrs = Ash.Changeset.get_argument(changeset, :attrs) || %{}

        attrs
        |> Enum.reduce(changeset, fn {key, value}, acc ->
          Ash.Changeset.change_attribute(acc, key, value)
        end)
        |> Ash.Changeset.change_attribute(:status, :active)
      end
    end

    update :revoke do
      description "Revoke this session — flips status and stamps revoked_at/by"
      require_atomic? false
      argument :revoked_by, :string, allow_nil?: false

      change fn changeset, _context ->
        revoked_by = Ash.Changeset.get_argument(changeset, :revoked_by)

        changeset
        |> Ash.Changeset.change_attribute(:status, :revoked)
        |> Ash.Changeset.change_attribute(:revoked_at, DateTime.utc_now())
        |> Ash.Changeset.change_attribute(:revoked_by, revoked_by)
      end
    end

    update :record_use do
      description "Bump last_used_at — called from the ApiAuth plug on a successful JWT validate"
      change atomic_update(:last_used_at, expr(now()))
      change atomic_update(:use_count, expr(use_count + 1))
    end

    update :mark_expired do
      description "Cleanup transition — JWT TTL elapsed"
      change set_attribute(:status, :expired)
    end

    destroy :destroy do
      primary? true
    end
  end

  policies do
    import ServiceRadar.Policies

    # Controller / cleanup worker run as system actors.
    system_bypass()

    # Read paths gated on the cli.session.read_* permissions.
    policy action(:by_jti) do
      authorize_if actor_attribute_equals(:role, :system)
      authorize_if {ActorHasPermission, permission: "cli.session.read_any"}
    end

    policy action(:active_by_user) do
      # Admin-style: anyone with read_any may scope by any user_id.
      authorize_if {ActorHasPermission, permission: "cli.session.read_any"}

      # Self-scope: the requested user_id must match the actor's id. The
      # default RBAC catalog grants cli.session.read_own to every role, so
      # this is the path the LiveView Settings page uses for non-admins.
      authorize_if expr(^arg(:user_id) == ^actor(:id))
    end

    policy action([:active, :read, :expired_active]) do
      authorize_if actor_attribute_equals(:role, :system)

      authorize_if {ActorHasPermission, permission: "cli.session.read_any"}
    end

    # Revoke gated on the matching cli.session.revoke_* permission. The
    # Settings LiveView's `ensure_can_revoke/2` enforces own-vs-any at the
    # call site; the resource policy here mirrors the read pattern.
    policy action(:revoke) do
      authorize_if actor_attribute_equals(:role, :system)

      authorize_if {ActorHasPermission, permission: "cli.session.revoke_any"}

      authorize_if expr(user_id == ^actor(:id))
    end

    # Inserts + housekeeping run as system actors.
    policy action([:create, :record_use, :mark_expired, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :jti, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "JWT id claim — links this session to the issued bearer token"
    end

    attribute :device_authorization_id, :uuid do
      public? true
      description "DeviceAuthorization row that produced this session"
    end

    attribute :user_id, :uuid do
      allow_nil? false
      public? true
      description "User the session belongs to (and whose permissions the JWT carries)"
    end

    attribute :client_id, :string do
      allow_nil? false
      public? true
      description "OAuth client identifier (e.g. \"serviceradar-cli\")"
    end

    attribute :scope, :string do
      allow_nil? false
      public? true
      description "Space-separated scopes granted on this session"
    end

    attribute :status, :atom do
      allow_nil? false
      default :active
      constraints one_of: @valid_statuses
      public? true
    end

    attribute :issued_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_used_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_used_ip, :string do
      public? true
    end

    attribute :use_count, :integer do
      default 0
      public? true
    end

    attribute :revoked_at, :utc_datetime_usec do
      public? true
    end

    attribute :revoked_by, :string do
      public? true
      description "Identifier of the actor that revoked the session (user id or 'system')"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, ServiceRadar.Identity.User do
      source_attribute :user_id
      destination_attribute :id
      allow_nil? false
      public? true
      define_attribute? false
    end

    belongs_to :device_authorization, ServiceRadar.Identity.DeviceAuthorization do
      source_attribute :device_authorization_id
      destination_attribute :id
      allow_nil? true
      public? true
      define_attribute? false
    end
  end

  calculations do
    calculate :is_active,
              :boolean,
              expr(status == :active and expires_at > now())

    calculate :is_expired, :boolean, expr(expires_at <= now())

    calculate :is_revoked, :boolean, expr(status == :revoked)
  end
end
