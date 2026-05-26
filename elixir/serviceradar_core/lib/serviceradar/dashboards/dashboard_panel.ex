defmodule ServiceRadar.Dashboards.DashboardPanel do
  @moduledoc """
  A single SRQL-backed panel on an authored dashboard.
  """

  use Ash.Resource,
    domain: ServiceRadar.Dashboards,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "analytics.view"}
  @view_all_check {ActorHasPermission, permission: "analytics.dashboards.view_all"}
  @edit_check {ActorHasPermission, permission: "analytics.dashboards.edit"}

  @fields [
    :dashboard_id,
    :dataset_key,
    :title,
    :srql_query,
    :builder_state,
    :visual_type,
    :data_binding,
    :display_config,
    :visual_config,
    :field_metadata,
    :layout,
    :refresh_interval_seconds,
    :position,
    :metadata
  ]

  postgres do
    table "authored_dashboard_panels"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false

    references do
      reference :dashboard, on_delete: :delete
    end
  end

  code_interface do
    define :list, action: :read
    define :list_for_dashboard, action: :for_dashboard, args: [:dashboard_id]
    define :get_by_id, action: :by_id, args: [:id]
    define :create_panel, action: :create
    define :update_panel, action: :update
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :for_dashboard do
      argument :dashboard_id, :uuid, allow_nil?: false
      filter expr(dashboard_id == ^arg(:dashboard_id))
      prepare build(sort: [position: :asc, inserted_at: :asc])
    end

    create :create do
      accept @fields
    end

    update :update do
      accept @fields -- [:dashboard_id]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      forbid_unless @view_check
      authorize_if @view_all_check
      authorize_if ServiceRadar.Dashboards.Checks.ActorCanAccessDashboardChild
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if @edit_check
      authorize_if ServiceRadar.Dashboards.Checks.ActorCanEditDashboardChild
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :dashboard_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :dataset_key, :string do
      allow_nil? false
      public? true
      default "primary"
      description "Named dashboard dataset consumed by this panel."
    end

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :srql_query, :string do
      allow_nil? false
      public? true
    end

    attribute :builder_state, :map do
      allow_nil? false
      public? true
      default %{}
      description "Persisted SRQL builder state when the query can be represented visually."
    end

    attribute :visual_type, :atom do
      allow_nil? false
      public? true
      default :table

      constraints one_of: [
                    :table,
                    :stat,
                    :count,
                    :gauge,
                    :availability,
                    :line,
                    :area,
                    :bar,
                    :category,
                    :status_list,
                    :pivot
                  ]
    end

    attribute :data_binding, :map do
      allow_nil? false
      public? true
      default %{}
      description "Explicit dataset field, JSON path, label, grouping, and aggregation bindings."
    end

    attribute :display_config, :map do
      allow_nil? false
      public? true
      default %{}
      description "Labels, captions, units, thresholds, legends, and renderer choices."
    end

    attribute :visual_config, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :field_metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :layout, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :refresh_interval_seconds, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0, max: 86_400
    end

    attribute :position, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :dashboard, ServiceRadar.Dashboards.AuthoredDashboard do
      allow_nil? false
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :dashboard_id
    end
  end
end
