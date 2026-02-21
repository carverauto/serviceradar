defmodule ServiceRadar.Plugins.PluginTargetPolicy do
  @moduledoc """
  Policy definition for query-driven plugin targeting.

  A policy stores SRQL input definitions and runtime settings. Reconciliation
  resolves the policy inputs server-side and materializes policy-derived plugin
  assignments for agents.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "plugin_target_policies"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :plugin_package, on_delete: :delete
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_enabled, action: :enabled
    define :preview, action: :preview
    define :reconcile_now, action: :reconcile_now
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    read :enabled do
      filter expr(enabled == true)
    end

    create :create do
      accept [
        :name,
        :description,
        :plugin_package_id,
        :input_definitions,
        :params_template,
        :interval_seconds,
        :timeout_seconds,
        :chunk_size,
        :max_targets,
        :enabled
      ]
    end

    update :update do
      accept [
        :name,
        :description,
        :plugin_package_id,
        :input_definitions,
        :params_template,
        :interval_seconds,
        :timeout_seconds,
        :chunk_size,
        :max_targets,
        :enabled,
        :last_reconciled_at,
        :last_reconcile_summary
      ]
    end

    action :preview do
      argument :id, :uuid, allow_nil?: false
      argument :sample_limit, :integer, allow_nil?: true, default: 10

      run fn input, context ->
        ServiceRadar.Plugins.PluginTargetPolicyOps.preview_by_id(
          input.arguments.id,
          sample_limit: input.arguments.sample_limit,
          actor: context[:actor]
        )
      end
    end

    action :reconcile_now do
      argument :id, :uuid, allow_nil?: false

      run fn input, context ->
        ServiceRadar.Plugins.PluginTargetPolicyOps.reconcile_by_id(
          input.arguments.id,
          actor: context[:actor]
        )
      end
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:create, :update, :destroy, :preview, :reconcile_now]) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.plugins.manage"}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :plugin_package_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :input_definitions, {:array, :map} do
      allow_nil? false
      public? true
      default []
    end

    attribute :params_template, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :interval_seconds, :integer do
      allow_nil? false
      public? true
      default 60
      constraints min: 10, max: 86_400
    end

    attribute :timeout_seconds, :integer do
      allow_nil? false
      public? true
      default 10
      constraints min: 1, max: 3_600
    end

    attribute :chunk_size, :integer do
      allow_nil? false
      public? true
      default 100
      constraints min: 1, max: 500
    end

    attribute :max_targets, :integer do
      allow_nil? false
      public? true
      default 10_000
      constraints min: 1, max: 1_000_000
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :last_reconciled_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_reconcile_summary, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :plugin_package, ServiceRadar.Plugins.PluginPackage do
      allow_nil? false
      public? true
      destination_attribute :id
      source_attribute :plugin_package_id
      define_attribute? false
    end
  end
end
