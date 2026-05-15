defmodule ServiceRadar.Identity.DeviceAuthorization do
  @moduledoc """
  Pending RFC 8628 (OAuth 2.0 Device Authorization Grant) authorization rows.

  The CLI hits `POST /api/v1/cli/auth/device` to mint one of these, then
  polls `POST /api/v1/cli/auth/token` until the user approves or denies via
  the `/cli/auth/device` LiveView. Approved rows produce a `CliSession` row
  on the next successful poll (the JWT itself is issued from
  `ServiceRadarWebNG.Auth.Guardian`).

  Only the SHA-256 hash of `device_code` is stored; the plaintext goes back
  to the CLI exactly once. `user_code` is stored verbatim so the LiveView
  can look it up by user-typed value (it's already short, dashed, and
  alphabet-restricted to be unguessable in the 15-minute TTL window).

  Status transitions (no other moves are valid):

      :pending -> :approved   (user clicked Approve in the LiveView)
      :pending -> :denied     (user clicked Deny)
      :pending -> :expired    (TTL hit before user acted, or cleanup job ran)
      :approved -> :expired   (linked CliSession's JWT TTL elapsed)
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @valid_statuses [:pending, :approved, :denied, :expired]

  postgres do
    table "device_authorizations"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :create, args: [:attrs]
    define :get_by_user_code, action: :by_user_code, args: [:user_code]
    define :get_by_device_code_hash, action: :by_device_code_hash, args: [:device_code_hash]
    define :list_by_user, action: :by_user, args: [:user_id]
    define :approve, args: [:user_id]
    define :deny, args: []
    define :record_poll, args: []
    define :slow_down, args: []
    define :expire, args: []
  end

  actions do
    defaults [:read]

    read :by_user_code do
      argument :user_code, :string, allow_nil?: false
      get? true
      filter expr(user_code == ^arg(:user_code))
    end

    read :by_device_code_hash do
      argument :device_code_hash, :string, allow_nil?: false
      get? true
      filter expr(device_code_hash == ^arg(:device_code_hash))
    end

    read :by_user do
      description "Active device authorizations for a given user (post-approval)"
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    read :pending_active do
      description "Pending rows whose TTL has not yet elapsed"
      filter expr(status == :pending and expires_at > now())
    end

    read :pending_expired do
      description "Pending rows past their TTL — candidates for cleanup"
      filter expr(status == :pending and expires_at <= now())
    end

    create :create do
      description "Mint a new device authorization (called from the device endpoint)"

      accept [
        :device_code_hash,
        :user_code,
        :client_id,
        :scope,
        :expires_at,
        :interval_seconds
      ]

      argument :attrs, :map, allow_nil?: false

      change fn changeset, _context ->
        attrs = Ash.Changeset.get_argument(changeset, :attrs) || %{}

        attrs
        |> Enum.reduce(changeset, fn {key, value}, acc ->
          Ash.Changeset.change_attribute(acc, key, value)
        end)
        |> Ash.Changeset.change_attribute(:status, :pending)
      end
    end

    update :approve do
      description "Mark the row approved by `user_id`"
      require_atomic? false
      argument :user_id, :uuid, allow_nil?: false

      change fn changeset, _context ->
        user_id = Ash.Changeset.get_argument(changeset, :user_id)

        changeset
        |> Ash.Changeset.change_attribute(:status, :approved)
        |> Ash.Changeset.change_attribute(:user_id, user_id)
        |> Ash.Changeset.change_attribute(:approved_at, DateTime.utc_now())
      end
    end

    update :deny do
      description "Mark the row denied by the resource owner"
      change set_attribute(:status, :denied)
    end

    update :record_poll do
      description "Bump last_polled_at — called from the token endpoint on every poll"
      change atomic_update(:last_polled_at, expr(now()))
    end

    update :slow_down do
      description "Bump interval_seconds by 5 when the CLI polls faster than allowed"
      change atomic_update(:interval_seconds, expr(interval_seconds + 5))
    end

    update :expire do
      description "Mark the row expired (cleanup job, or post-TTL on poll)"
      change set_attribute(:status, :expired)
    end

    destroy :destroy do
      primary? true
    end
  end

  policies do
    import ServiceRadar.Policies

    # System actors (the controller calling Guardian, the cleanup worker)
    # bypass policies; user-facing actions are gated below.
    system_bypass()

    # Anyone can read by user_code or device_code_hash — these are
    # unguessable and represent the entire OAuth flow's contract.
    policy action(:by_user_code) do
      authorize_if always()
    end

    policy action(:by_device_code_hash) do
      authorize_if always()
    end

    # Listing rows for an arbitrary user is admin-only; users can list
    # their own.
    policy action(:by_user) do
      authorize_if expr(^arg(:user_id) == ^actor(:id))
      authorize_if is_admin()
    end

    # The cleanup-list reads are system-only.
    policy action([:pending_active, :pending_expired, :read]) do
      authorize_if actor_attribute_equals(:role, :system)
      authorize_if is_admin()
    end

    # Anyone with `cli.session.create` can approve / deny their own pending
    # codes. The LiveView re-checks this before exposing the buttons.
    policy action([:approve, :deny]) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "cli.session.create"}

      authorize_if is_admin()
    end

    # Polling-side updates run from the controller as a system actor.
    policy action([:record_poll, :slow_down, :expire, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # Inserts come from the controller as a system actor.
    policy action(:create) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :device_code_hash, :string do
      allow_nil? false
      public? false
      sensitive? true
      description "SHA-256 hex hash of the plaintext device_code"
    end

    attribute :user_code, :string do
      allow_nil? false
      public? true
      description "User-facing 9-char dashed code (XXXX-XXXX) the user types into the LiveView"
    end

    attribute :client_id, :string do
      allow_nil? false
      public? true
      description "OAuth client identifier (e.g. \"serviceradar-cli\")"
    end

    attribute :scope, :string do
      allow_nil? false
      public? true
      description "Space-separated requested scopes"
    end

    attribute :status, :atom do
      allow_nil? false
      default :pending
      constraints one_of: @valid_statuses
      public? true
    end

    attribute :user_id, :uuid do
      public? true
      description "Approving user — set when status flips to :approved"
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When this device authorization stops accepting polls"
    end

    attribute :interval_seconds, :integer do
      allow_nil? false
      default 5
      public? true
      description "RFC 8628 polling interval; bumped by :slow_down"
    end

    attribute :last_polled_at, :utc_datetime_usec do
      public? true
    end

    attribute :approved_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, ServiceRadar.Identity.User do
      source_attribute :user_id
      destination_attribute :id
      allow_nil? true
      public? true
      define_attribute? false
    end
  end

  identities do
    identity :unique_user_code, [:user_code]
    identity :unique_device_code_hash, [:device_code_hash]
  end
end
