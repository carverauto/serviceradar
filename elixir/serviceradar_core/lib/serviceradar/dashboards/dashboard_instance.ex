defmodule ServiceRadar.Dashboards.DashboardInstance do
  @moduledoc """
  Enabled dashboard placement backed by a dashboard package.
  """

  use Ash.Resource,
    domain: ServiceRadar.Dashboards,
    data_layer: AshPostgres.DataLayer

  @fields [
    :dashboard_package_id,
    :name,
    :route_slug,
    :placement,
    :enabled,
    :is_default,
    :settings,
    :metadata
  ]

  postgres do
    table "dashboard_instances"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false

    references do
      reference :dashboard_package, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    read :enabled do
      filter expr(enabled == true)
    end

    read :by_placement do
      argument :placement, :atom, allow_nil?: false
      filter expr(placement == ^arg(:placement) and enabled == true)
    end

    create :create do
      accept @fields
    end

    create :upsert do
      accept @fields
      upsert? true
      upsert_identity :unique_route_slug
      upsert_fields List.delete(@fields, :route_slug) ++ [:updated_at]
    end

    update :update do
      accept @fields
    end

    update :enable do
      accept []
      change set_attribute(:enabled, true)
    end

    update :disable do
      accept []
      change set_attribute(:enabled, false)
    end

    update :set_default do
      accept [:is_default]
      change set_attribute(:is_default, true)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :route_slug, :string do
      allow_nil? false
      public? true
      description "Stable route segment used by the dashboard host"
    end

    attribute :placement, :atom do
      allow_nil? false
      public? true
      default :dashboard
      constraints one_of: [:dashboard, :map, :custom]
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :is_default, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :settings, :map do
      allow_nil? false
      public? true
      default %{}
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
    belongs_to :dashboard_package, ServiceRadar.Dashboards.DashboardPackage do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_route_slug, [:route_slug]
  end
end
