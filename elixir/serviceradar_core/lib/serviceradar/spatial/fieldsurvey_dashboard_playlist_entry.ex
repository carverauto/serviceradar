defmodule ServiceRadar.Spatial.FieldSurveyDashboardPlaylistEntry do
  @moduledoc """
  Dashboard playlist entries that select persisted FieldSurvey heatmaps using SRQL.
  """
  use Ash.Resource,
    domain: ServiceRadar.Spatial,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @networks_manage_check {ActorHasPermission, permission: "settings.networks.manage"}
  @settings_view_check {ActorHasPermission, permission: "settings.view"}
  @type t :: %__MODULE__{}

  postgres do
    table("fieldsurvey_dashboard_playlist_entries")
    repo(ServiceRadar.Repo)
    schema("platform")
    migrate?(false)
  end

  code_interface do
    define(:get_by_id, action: :by_id, args: [:id])
    define(:list, action: :list)
    define(:create, action: :create)
    define(:update, action: :update)
    define(:destroy, action: :destroy)
  end

  actions do
    defaults([:read, :destroy])

    read :by_id do
      argument(:id, :uuid, allow_nil?: false)
      get?(true)
      filter(expr(id == ^arg(:id)))
    end

    read :list do
      prepare(fn query, _ ->
        Ash.Query.sort(query, sort_order: :asc, inserted_at: :asc)
      end)
    end

    create :create do
      primary?(true)

      accept([
        :label,
        :srql_query,
        :enabled,
        :sort_order,
        :overlay_type,
        :display_mode,
        :dwell_seconds,
        :max_age_seconds,
        :metadata
      ])
    end

    update :update do
      accept([
        :label,
        :srql_query,
        :enabled,
        :sort_order,
        :overlay_type,
        :display_mode,
        :dwell_seconds,
        :max_age_seconds,
        :metadata
      ])
    end
  end

  policies do
    bypass always() do
      authorize_if(actor_attribute_equals(:role, :system))
    end

    policy action_type(:read) do
      authorize_if(@settings_view_check)
    end

    policy action([:create, :update, :destroy]) do
      authorize_if(@networks_manage_check)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :label, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: 160)
    end

    attribute :srql_query, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: 2_000)
    end

    attribute :enabled, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    attribute :sort_order, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :overlay_type, :string do
      allow_nil?(false)
      default("wifi_rssi")
      public?(true)
      constraints(max_length: 64)
    end

    attribute :display_mode, :string do
      allow_nil?(false)
      default("compact_heatmap")
      public?(true)
      constraints(max_length: 64)
    end

    attribute :dwell_seconds, :integer do
      allow_nil?(false)
      default(30)
      public?(true)
      constraints(min: 5, max: 3_600)
    end

    attribute :max_age_seconds, :integer do
      allow_nil?(false)
      default(86_400)
      public?(true)
      constraints(min: 60, max: 31_536_000)
    end

    attribute :metadata, :map do
      allow_nil?(false)
      default(%{})
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
