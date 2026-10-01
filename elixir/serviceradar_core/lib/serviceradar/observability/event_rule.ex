defmodule ServiceRadar.Observability.EventRule do
  @moduledoc """
  Unified rules for creating OCSF events from multiple sources.

  Log-based rules mirror legacy log promotion rules. Metric-based rules
  are created from interface metric configurations and generate events
  directly without a log promotion step.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @event_rule_fields [:name, :enabled, :priority, :source_type, :source, :match, :event]

  postgres do
    table "event_rules"
    repo ServiceRadar.Repo
    schema "platform"
  end

  json_api do
    type "event-rule"

    routes do
      base "/event-rules"
      get :by_id
      index :read
      index :active, route: "/active"
      post :create
      patch :update, read_action: :for_update
      delete :destroy, read_action: :for_destroy
    end
  end

  code_interface do
    define :list, action: :read
    define :list_active, action: :active
    define :create, action: :create
    define :update, action: :update
    define :destroy, action: :destroy
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :active do
      filter expr(enabled == true)
      prepare build(sort: [priority: :asc, inserted_at: :asc])
    end

    read :for_update
    read :for_destroy

    create :create do
      accept @event_rule_fields
      change {__MODULE__.InvalidateLogPromotionRulesCache, []}
    end

    update :update do
      accept @event_rule_fields
      atomic_upgrade_with :for_update
      change {__MODULE__.InvalidateLogPromotionRulesCache, []}
    end

    destroy :destroy do
      primary? true
      atomic_upgrade_with :for_destroy
      change {__MODULE__.InvalidateLogPromotionRulesCache, []}
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission(
      [:read, :by_id, :active],
      {ActorHasPermission, permission: "observability.rules.view"}
    )

    action_with_permission(
      :create,
      {ActorHasPermission, permission: "observability.rules.create"}
    )

    action_with_permission(
      [:update, :for_update],
      {ActorHasPermission, permission: "observability.rules.update"}
    )

    action_with_permission(
      [:destroy, :for_destroy],
      {ActorHasPermission, permission: "observability.rules.delete"}
    )
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :enabled, :boolean do
      default true
      public? true
    end

    attribute :priority, :integer do
      default 100
      public? true
    end

    attribute :source_type, :atom do
      allow_nil? false
      default :log
      public? true
      constraints one_of: [:log, :metric]
    end

    attribute :source, :map do
      default %{}
      public? true
    end

    attribute :match, :map do
      default %{}
      public? true
    end

    attribute :event, :map do
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_name, [:name]
  end

  defmodule InvalidateLogPromotionRulesCache do
    @moduledoc false

    use Ash.Resource.Change

    alias ServiceRadar.Changes.AfterAction
    alias ServiceRadar.Observability.LogPromotion

    @impl true
    def change(changeset, _opts, _context) do
      AfterAction.after_action(changeset, fn _record ->
        LogPromotion.invalidate_rules_cache()
      end)
    end

    @impl true
    def atomic(changeset, opts, context) do
      {:ok, change(changeset, opts, context)}
    end
  end
end
