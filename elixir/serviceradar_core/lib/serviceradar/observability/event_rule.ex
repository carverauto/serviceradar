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
    authorizers: [Ash.Policy.Authorizer]

  @event_rule_fields [:name, :enabled, :priority, :source_type, :source, :match, :event]

  postgres do
    table "event_rules"
    repo ServiceRadar.Repo
    schema "platform"
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

    read :active do
      filter expr(enabled == true)
      prepare build(sort: [priority: :asc, inserted_at: :asc])
    end

    create :create do
      accept @event_rule_fields
      change {__MODULE__.InvalidateLogPromotionRulesCache, []}
    end

    update :update do
      accept @event_rule_fields
      change {__MODULE__.InvalidateLogPromotionRulesCache, []}
    end

    destroy :destroy do
      primary? true
      change {__MODULE__.InvalidateLogPromotionRulesCache, []}
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action([:create, :update, :destroy])
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
    def atomic(_changeset, _opts, _context), do: :ok
  end
end
