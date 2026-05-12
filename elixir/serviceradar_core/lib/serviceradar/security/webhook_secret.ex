defmodule ServiceRadar.Security.WebhookSecret do
  @moduledoc """
  Encrypted shared secret used to verify inbound webhook signatures
  (HMAC-SHA256). Keyed by `source_name` (e.g. `"falco"`, `"partner_x"`).

  At any moment a given `source_name` has exactly one secret with
  `active? = true`. Rotation flips the active record's `active? = false`
  and sets `grace_until = now + grace`. During the grace window the
  signature plug accepts either the new active secret or the recently
  superseded one, so callers have time to roll their config without an
  outage. After `grace_until` passes, the superseded record is no
  longer accepted; a periodic job (added later) garbage-collects
  records whose grace expired more than 24h ago.
  """

  use Ash.Resource,
    domain: ServiceRadar.Security,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak, AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "webhook_secrets"
    repo ServiceRadar.Repo
    schema "platform"
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:secret])
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "webhook_secret_versions"
    mixin {ServiceRadar.Security.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at, :secret]
  end

  code_interface do
    define :list, action: :read
    define :get_by_source, action: :by_source, args: [:source_name]
    define :get_active_by_source, action: :active_by_source, args: [:source_name]
    define :verifiable_for_source, action: :verifiable_for_source, args: [:source_name]
    define :create_secret, action: :create
    define :rotate_secret, action: :rotate, args: [:source_name, :secret, :grace_seconds]
    define :touch_last_used, action: :touch_last_used
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:source_name, :secret]

      change set_attribute(:active?, true)
      change set_attribute(:rotated_at, &DateTime.utc_now/0)
    end

    read :by_source do
      argument :source_name, :string, allow_nil?: false
      filter expr(source_name == ^arg(:source_name))
    end

    read :active_by_source do
      argument :source_name, :string, allow_nil?: false
      get? true
      filter expr(source_name == ^arg(:source_name) and active? == true)
    end

    read :verifiable_for_source do
      argument :source_name, :string, allow_nil?: false

      filter expr(
               source_name == ^arg(:source_name) and
                 (active? == true or
                    (active? == false and not is_nil(grace_until) and grace_until > now()))
             )
    end

    update :touch_last_used do
      accept []
      change set_attribute(:last_used_at, &DateTime.utc_now/0)
    end

    action :rotate, :struct do
      constraints instance_of: __MODULE__
      argument :source_name, :string, allow_nil?: false
      argument :secret, :string, allow_nil?: false, sensitive?: true
      argument :grace_seconds, :integer, default: 300

      run fn input, _ctx ->
        ServiceRadar.Security.WebhookSecret.Rotate.run(input.arguments)
      end
    end

    update :supersede do
      accept [:grace_until]
      change set_attribute(:active?, false)
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

    attribute :source_name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
    end

    attribute :secret, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :active?, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :grace_until, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :rotated_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_used_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    timestamps()
  end

  identities do
    identity :one_active_per_source, [:source_name],
      where: expr(active? == true),
      message: "another active secret already exists for this source"
  end
end
