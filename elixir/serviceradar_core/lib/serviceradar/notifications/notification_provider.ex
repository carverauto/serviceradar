defmodule ServiceRadar.Notifications.NotificationProvider do
  @moduledoc """
  A *kind* of notification destination.

  A provider describes how a class of destinations is reached; a
  `ServiceRadar.Notifications.NotificationChannel` is a configured instance of
  one ("Slack #noc"). Providers are the ONLY extensible boundary in the
  notification platform - the decision engine (routing, fan-out, escalation,
  deduplication, suppression, acknowledgement) never branches on
  `provider_type` (design D1).

  ## Tiers (design D2)

  There are exactly THREE extensibility tiers:

  - `:native` - an Elixir module resolved from a compile-time allowlist.
  - `:declarative` - an uploaded HTTP request template document. No code, no
    release.
  - `:wasm_plugin` - a signed OCI bundle executed on the existing wazero host.

  PLUS the built-in `:stream` provider type. `:stream` is a `provider_type` but
  it is NOT an extensibility tier, because operators cannot author one: it ships
  seeded as a first-party managed provider (design D10) and publishes the
  canonical envelope to a JetStream subject plus an RBAC-scoped Phoenix Channel.

  Every provider, in every tier, MUST declare both `:send` and `:test` in
  `capabilities`, so "test-send before saving" works uniformly (design D2). That
  is enforced here by
  `ServiceRadar.Notifications.Validations.ProviderTransportContract` rather than
  being left to the manifest validator, which only sees the `:wasm_plugin` tier.

  ## The plugin reference (design R2, tasks 1.1.2a and 3.1.1b)

  Phase 1 REJECTED `provider_type: :wasm_plugin` outright, because there was no
  `notifications:` manifest block to resolve `{plugin_package_id, action_key}`
  against and no agent-side `notify:v1` enforcement, so a plugin provider saved
  then would have been a configuration dispatch could not resolve. Phase 3 added
  both, so that guard is gone and the reference is checked for real:

  - `notification_providers_plugin_ref` (below) requires a `:wasm_plugin` row to
    carry BOTH `plugin_package_id` and `action_key`, and every other tier to
    carry neither.
  - `ServiceRadar.Notifications.Validations.ProviderActionKeyDeclared` requires
    `action_key` to name a `key` in the referenced package's validated
    `notifications:` block, so a typo fails at save rather than at the first
    page.

  ## Field coherence

  The three tier-shaped CHECK constraints in
  `20260809120000_create_notification_platform_tables.exs` are mirrored here as
  Ash validations so a bad record fails with an actionable field error instead
  of a raw constraint violation:

  - `notification_providers_plugin_ref` - `:wasm_plugin` <-> both
    `plugin_package_id` and `action_key`; every other tier has neither. This
    also encodes tasks 1.1.2a's "an `action_key` without a `plugin_package_id`
    is invalid".
  - `notification_providers_native_module` - `:native` <-> `implementation_module`.
  - `notification_providers_declarative_definition` - `:declarative` <-> `definition`.

  ## Module resolution

  `implementation_module` is stored as a string and validated against
  `@implementation_module_allowlist`, a compile-time list. It is NEVER resolved
  with `String.to_atom/1` on operator input (design D2, tasks 1.4.3). Note that
  the `:stream` transport appears in the allowlist for the registry's benefit
  only: the native-module CHECK constraint requires `implementation_module` to
  be NULL on a `:stream` row, so the stream transport is reached through the
  provider type, never through this column.

  ## Seed reconciliation

  First-party providers ship `managed: true` with a `template_version` and
  `template_fingerprint`, following `ServiceRadar.Observability.PresetRuleResource`.
  `:seed_managed` upserts on `provider_key` and deliberately excludes `status`
  from `upsert_fields` so an upgrade cannot re-enable a provider an operator
  disabled.

  See `openspec/changes/add-notification-platform/design.md`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Notifications,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Notifications.Transports.Registry, as: TransportRegistry
  alias ServiceRadar.Notifications.Validations.ProviderActionKeyDeclared
  alias ServiceRadar.Notifications.Validations.ProviderPackageApproved
  alias ServiceRadar.Notifications.Validations.ProviderTransportContract
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @channels_view_check {ActorHasPermission, permission: "notifications.channels.view"}
  @routes_view_check {ActorHasPermission, permission: "notifications.routes.view"}
  @manage_check {ActorHasPermission, permission: "notifications.providers.manage"}

  @provider_types [:native, :declarative, :wasm_plugin, :stream]
  @extensibility_tiers [:native, :declarative, :wasm_plugin]

  @capabilities [
    :send,
    :test,
    :resolve_update,
    :inbound_callback,
    :rich_payload,
    :attachments,
    :threading
  ]

  @execution_routes [:control_plane, :edge_agent]

  @payload_formats [
    :slack_blocks,
    :discord_embed,
    :markdown,
    :plain,
    :html,
    :pagerduty_v2,
    :json
  ]

  @sources [:first_party, :uploaded, :plugin]

  # Compile-time allowlist of transport modules a `:native` provider may name.
  #
  # The list is NOT duplicated here. `ServiceRadar.Notifications.Transports.Registry`
  # owns it, and dispatch resolves through the same list this validation admits;
  # a second copy would eventually accept a name dispatch cannot resolve, or
  # refuse one it can.
  @implementation_module_allowlist TransportRegistry.allowlisted_module_names()

  @fields [
    :provider_key,
    :provider_type,
    :display_name,
    :description,
    :icon,
    :config_schema,
    :capabilities,
    :supported_routes,
    :payload_formats,
    :definition,
    :definition_version,
    :plugin_package_id,
    :action_key,
    :implementation_module,
    :source,
    :status,
    :default_max_attempts,
    :managed,
    :template_version,
    :template_fingerprint,
    :metadata
  ]

  # `provider_key` and `provider_type` are create-only: changing the tier of a
  # live provider would invalidate every channel configured against its
  # `config_schema`. `plugin_package_id` / `action_key` are Phase 3 fields and
  # get their own action there.
  @updatable_fields [
    :display_name,
    :description,
    :icon,
    :config_schema,
    :capabilities,
    :supported_routes,
    :payload_formats,
    :definition,
    :definition_version,
    :implementation_module,
    :source,
    :default_max_attempts,
    :managed,
    :template_version,
    :template_fingerprint,
    :metadata
  ]

  @doc "Provider types recognised by the platform, including the built-in `:stream`."
  def provider_types, do: @provider_types

  @doc "The three extensibility tiers. `:stream` is deliberately absent."
  def extensibility_tiers, do: @extensibility_tiers

  @doc "Compile-time allowlist of `:native` transport modules."
  def implementation_module_allowlist, do: @implementation_module_allowlist

  @doc """
  Capabilities a provider may declare.

  `ServiceRadar.Plugins.Manifest` keeps a second, string-valued copy of this
  vocabulary for the `notifications:` block, because naming this resource from
  the manifest validator would close a compile cycle through
  `Plugins.PluginPackage`. This accessor exists so a test can assert the two
  stay equal rather than discovering the drift when a plugin declares a
  capability the provider row cannot store.
  """
  def capabilities, do: @capabilities

  @doc "Payload formats a provider may declare. Mirrored in `Plugins.Manifest`."
  def payload_formats, do: @payload_formats

  @doc "Execution routes a provider may support. Mirrored in `Plugins.Manifest`."
  def execution_routes, do: @execution_routes

  postgres do
    table "notification_providers"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_provider_key: "notification_providers_provider_key_uidx"

    references do
      reference :plugin_package, on_delete: :restrict
    end
  end

  state_machine do
    initial_states [:draft]
    default_initial_state :draft
    state_attribute :status

    transitions do
      transition :activate, from: [:draft, :disabled], to: :active
      transition :disable, from: [:draft, :active], to: :disabled
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "notification_provider_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_provider_key, action: :by_provider_key, args: [:provider_key]
    define :list_active, action: :active
    define :list_by_type, action: :by_provider_type, args: [:provider_type]
    define :create_provider, action: :create
    define :seed_managed, action: :seed_managed
    define :update_provider, action: :update
    define :activate, action: :activate
    define :disable, action: :disable
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :by_provider_key do
      argument :provider_key, :string, allow_nil?: false
      get? true
      filter expr(provider_key == ^arg(:provider_key))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :active do
      filter expr(status == :active)
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :by_provider_type do
      argument :provider_type, :atom do
        allow_nil? false
        constraints one_of: @provider_types
      end

      filter expr(provider_type == ^arg(:provider_type))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    create :create do
      description "Register a provider. Starts in :draft until explicitly activated."
      accept List.delete(@fields, :status)
    end

    create :seed_managed do
      description """
      Upsert a first-party managed provider during seed reconciliation. `status`
      is excluded from `upsert_fields` so an upgrade never re-enables a provider
      an operator disabled.
      """

      upsert? true
      upsert_identity :unique_provider_key
      upsert_fields @updatable_fields

      accept List.delete(@fields, :status)

      change set_attribute(:managed, true)
    end

    update :update do
      accept @updatable_fields
    end

    update :activate do
      # tasks 3.3.2. Activation is the moment a plugin-backed provider becomes
      # usable, so it is the moment its package must be approved. Deliberately
      # not on `:create` (registering against a package still in review is a
      # normal workflow) and deliberately not on `:disable` (turning off a
      # provider whose package was revoked is the correct response, and must
      # not be blocked by the revocation itself).
      validate {ProviderPackageApproved, []}

      change transition_state(:active)
    end

    update :disable do
      change transition_state(:disabled)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    # A provider is visible to anyone who can read the surfaces that reference
    # it: the channel registry and the routing configuration.
    policy action_type(:read) do
      authorize_if @channels_view_check
      authorize_if @routes_view_check
    end

    action_type_with_permission([:create, :update, :destroy], @manage_check)
    action_with_permission([:seed_managed, :activate, :disable], @manage_check)
  end

  validations do
    # --- notification_providers_plugin_ref -------------------------------
    validate present([:plugin_package_id, :action_key]) do
      where attribute_equals(:provider_type, :wasm_plugin)

      message "a :wasm_plugin provider must reference both a plugin package and an action key"
    end

    validate absent([:plugin_package_id, :action_key]) do
      where attribute_does_not_equal(:provider_type, :wasm_plugin)

      message "only a :wasm_plugin provider may set plugin_package_id or action_key"
    end

    # --- notification_providers_native_module ----------------------------
    validate present(:implementation_module) do
      where attribute_equals(:provider_type, :native)
      message "a :native provider must name an allowlisted implementation module"
    end

    validate absent(:implementation_module) do
      where attribute_does_not_equal(:provider_type, :native)
      message "only a :native provider may set implementation_module"
    end

    validate one_of(:implementation_module, @implementation_module_allowlist) do
      where attribute_equals(:provider_type, :native)

      message """
      implementation_module must be one of the compile-time allowlisted \
      transports; a module is never resolved from operator input\
      """
    end

    # --- notification_providers_declarative_definition -------------------
    validate present(:definition) do
      where attribute_equals(:provider_type, :declarative)
      message "a :declarative provider must carry a request template definition"
    end

    validate absent(:definition) do
      where attribute_does_not_equal(:provider_type, :declarative)
      message "only a :declarative provider may set definition"
    end

    # `action_key` must name a notifier the referenced package's validated
    # `notifications:` manifest block actually declares (tasks 3.1.1b). This is
    # the half of the plugin reference Phase 1 could not enforce, because the
    # manifest block did not exist yet.
    validate {ProviderActionKeyDeclared, []}

    # --- transport contract (design D2) ----------------------------------
    validate {ProviderTransportContract, []}

    # `default_max_attempts` seeds NotificationChannel.max_attempts, which the
    # database constrains to >= 1 (notification_channels_max_attempts).
    validate compare(:default_max_attempts, greater_than_or_equal_to: 1) do
      message "default_max_attempts must be at least 1"
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :provider_key, :string do
      allow_nil? false
      public? true
      description "Stable operator-facing key: slack, discord, webhook, email, stream, ..."
    end

    attribute :provider_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: @provider_types

      description """
      Three extensibility tiers (:native, :declarative, :wasm_plugin) plus the \
      built-in, non-authorable :stream provider type.\
      """
    end

    attribute :display_name, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true
    attribute :icon, :string, allow_nil?: true, public?: true

    attribute :config_schema, :map do
      allow_nil? false
      public? true
      default %{}
      description "JSON Schema subset validated by ServiceRadar.Plugins.ConfigSchema"
    end

    attribute :capabilities, {:array, :atom} do
      allow_nil? false
      public? true
      default []
      constraints items: [one_of: @capabilities]
      description "Must include both :send and :test (design D2)"
    end

    attribute :supported_routes, {:array, :atom} do
      allow_nil? false
      public? true
      default [:control_plane]
      constraints items: [one_of: @execution_routes]
    end

    attribute :payload_formats, {:array, :atom} do
      allow_nil? false
      public? true
      default []
      constraints items: [one_of: @payload_formats]
    end

    attribute :definition, :map do
      allow_nil? true
      public? true
      description ":declarative only - the request template document"
    end

    attribute :definition_version, :integer do
      allow_nil? false
      public? true
      default 1

      description """
      Provider definition version, stamped onto every delivery this provider \
      renders as NotificationDelivery.provider_version.\
      """
    end

    attribute :plugin_package_id, :uuid do
      allow_nil? true
      public? true
      description ":wasm_plugin only, with action_key"
    end

    attribute :action_key, :string do
      allow_nil? true
      public? true

      description """
      :wasm_plugin only. Phase 3 additionally cross-checks that this equals a \
      `key` in the referenced package's validated `notifications:` manifest block.\
      """
    end

    attribute :implementation_module, :string do
      allow_nil? true
      public? true

      description """
      :native only. Resolved from a compile-time allowlist, never via \
      String.to_atom/1 on stored or operator input.\
      """
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      default :first_party
      constraints one_of: @sources
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:draft, :active, :disabled]
    end

    attribute :default_max_attempts, :integer do
      allow_nil? false
      public? true
      default 3
      description "Default for NotificationChannel.max_attempts on channels bound here"
    end

    attribute :managed, :boolean do
      allow_nil? false
      public? true
      default false
      description "First-party seeded row reconciled across releases"
    end

    attribute :template_version, :string, allow_nil?: true, public?: true
    attribute :template_fingerprint, :string, allow_nil?: true, public?: true

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :plugin_package, ServiceRadar.Plugins.PluginPackage do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :plugin_package_id
    end

    has_many :channels, ServiceRadar.Notifications.NotificationChannel do
      destination_attribute :provider_id
    end
  end

  identities do
    identity :unique_provider_key, [:provider_key]
  end
end
