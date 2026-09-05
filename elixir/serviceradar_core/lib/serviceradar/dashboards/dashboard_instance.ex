defmodule ServiceRadar.Dashboards.DashboardInstance do
  @moduledoc """
  Enabled dashboard placement backed by a dashboard package.
  """

  use Ash.Resource,
    domain: ServiceRadar.Dashboards,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Dashboards.Changes.RequireGroupAccessBoundary
  alias ServiceRadar.Dashboards.Checks.ActorCanAccessDashboardInstance
  alias ServiceRadar.Dashboards.Checks.ActorCanEditDashboardInstance
  alias ServiceRadar.Dashboards.Preparations.PolicyEditorAudience
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_all_check {ActorHasPermission, permission: "dashboards.packages.view_all"}
  @share_check {ActorHasPermission, permission: "dashboards.packages.share"}
  @enable_check {ActorHasPermission, permission: "dashboards.packages.enable"}
  @disable_check {ActorHasPermission, permission: "dashboards.packages.disable"}
  @publish_check {ActorHasPermission, permission: "dashboards.packages.publish"}
  @rbac_manage_check {ActorHasPermission, permission: "settings.rbac.manage"}
  @upsert_fields [
    :dashboard_package_id,
    :name,
    :placement,
    :enabled,
    :settings,
    :metadata,
    :updated_at
  ]

  @fields [
    :dashboard_package_id,
    :name,
    :route_slug,
    :placement,
    :enabled,
    :is_default,
    :visibility,
    :owner_id,
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
      reference :owner, on_delete: :nilify
    end
  end

  paper_trail do
    primary_key_type :uuid
    table_name "dashboard_instance_versions"
    mixin {ServiceRadar.Dashboards.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    reference_source? false
    create_version_on_destroy? true
    ignore_attributes [:inserted_at, :updated_at]
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :enabled do
      filter expr(enabled == true)
    end

    read :by_placement do
      argument :placement, :atom, allow_nil?: false
      filter expr(placement == ^arg(:placement) and enabled == true)
    end

    read :policy_editor_audience do
      argument :group_id, :uuid, allow_nil?: false
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 50
      prepare {PolicyEditorAudience, source: :package}
    end

    read :policy_editor_group_access_target do
      argument :id, :uuid, allow_nil?: false
      argument :group_id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare {PolicyEditorAudience, source: :package}
    end

    read :local_group_access_target do
      argument :id, :uuid, allow_nil?: false
      argument :group_id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare {PolicyEditorAudience, source: :package}
    end

    create :create do
      accept @fields
      change &put_default_visibility/2
    end

    create :upsert do
      accept @fields
      upsert? true
      upsert_identity :unique_route_slug
      # Keep owner, visibility, and is_default from the original row on republish.
      upsert_fields @upsert_fields
      change &put_default_visibility/2
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

    update :set_shared_for_policy_editor do
      accept []
      change set_attribute(:visibility, :shared)
      validate RequireGroupAccessBoundary
    end

    update :set_shared_for_local_group_access do
      accept []
      change set_attribute(:visibility, :shared)
      validate RequireGroupAccessBoundary
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action([:read, :by_id, :enabled, :by_placement]) do
      authorize_if @view_all_check
      authorize_if ActorCanAccessDashboardInstance
    end

    policy action([:policy_editor_audience, :policy_editor_group_access_target]) do
      forbid_unless @rbac_manage_check
      forbid_unless @share_check
      authorize_if @view_all_check
      authorize_if ActorCanEditDashboardInstance
    end

    policy action(:local_group_access_target) do
      authorize_if @share_check
      authorize_if ActorCanEditDashboardInstance
    end

    policy action(:set_shared_for_policy_editor) do
      forbid_unless @rbac_manage_check
      forbid_unless @share_check
      authorize_if @view_all_check
      authorize_if ActorCanEditDashboardInstance
    end

    policy action(:set_shared_for_local_group_access) do
      authorize_if @share_check
      authorize_if ActorCanEditDashboardInstance
    end

    policy action_type(:create) do
      authorize_if @publish_check
      authorize_if @enable_check
    end

    policy action([:enable, :set_default]) do
      authorize_if @enable_check
      authorize_if ActorCanEditDashboardInstance
    end

    policy action(:disable) do
      authorize_if @disable_check
      authorize_if ActorCanEditDashboardInstance
    end

    policy action(:update) do
      authorize_if @share_check
      authorize_if @enable_check
      authorize_if ActorCanEditDashboardInstance
    end

    policy action_type(:destroy) do
      authorize_if @enable_check
      authorize_if @share_check
      authorize_if ActorCanEditDashboardInstance
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

    attribute :visibility, :atom do
      allow_nil? false
      public? true
      default :public
      constraints one_of: [:private, :shared, :public]
    end

    attribute :owner_id, :uuid do
      public? true
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

    belongs_to :owner, ServiceRadar.Identity.User do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :owner_id
    end

    has_many :access_grants, ServiceRadar.Dashboards.DashboardInstanceAccessGrant do
      destination_attribute :dashboard_instance_id
    end
  end

  calculations do
    calculate :policy_editor_sort_key, :string, expr(fragment("lower(?)", name))
  end

  identities do
    identity :unique_route_slug, [:route_slug]
  end

  defp put_default_visibility(changeset, _context) do
    case Ash.Changeset.get_attribute(changeset, :visibility) do
      vis when vis in [:private, :shared, :public] ->
        changeset

      _ ->
        Ash.Changeset.force_change_attribute(changeset, :visibility, default_visibility())
    end
  end

  defp default_visibility do
    :serviceradar_core
    |> Application.get_env(:dashboard_packages, [])
    |> Keyword.get(:default_visibility, :public)
    |> case do
      value when value in [:private, :shared, :public] -> value
      "private" -> :private
      "shared" -> :shared
      _ -> :public
    end
  end
end
