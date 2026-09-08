defmodule ServiceRadar.Dashboards.AuthoredDashboard do
  @moduledoc """
  User-authored SRQL dashboard definition.

  Authored dashboards are first-class saved dashboards built from panels that
  run bounded SRQL queries and render through web-ng-owned visualization
  components. They are separate from signed dashboard packages.
  """

  use Ash.Resource,
    domain: ServiceRadar.Dashboards,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.AshContext
  alias ServiceRadar.Dashboards.Checks.ActorCanEditDashboard
  alias ServiceRadar.Dashboards.Preparations.PolicyEditorAudience
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "analytics.view"}
  @view_all_check {ActorHasPermission, permission: "analytics.dashboards.view_all"}
  @create_check {ActorHasPermission, permission: "analytics.dashboards.create"}
  @edit_check {ActorHasPermission, permission: "analytics.dashboards.edit"}
  @delete_check {ActorHasPermission, permission: "analytics.dashboards.delete"}
  @rbac_manage_check {ActorHasPermission, permission: "settings.rbac.manage"}
  @share_check {ActorHasPermission, permission: "analytics.dashboards.share"}

  @fields [
    :dashboard_ref,
    :title,
    :description,
    :slug,
    :owner_id,
    :visibility,
    :status,
    :default_time_range,
    :layout,
    :variables,
    :metadata
  ]

  postgres do
    table "authored_dashboards"
    repo ServiceRadar.Repo
    schema "platform"

    identity_wheres_to_sql unique_slug: "slug IS NOT NULL"
    migrate? false

    references do
      reference :owner, on_delete: :nilify
    end
  end

  paper_trail do
    primary_key_type :uuid
    table_name "authored_dashboard_versions"
    mixin {ServiceRadar.Dashboards.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? true
    ignore_attributes [:inserted_at, :updated_at, :archived_at]
  end

  code_interface do
    define :list, action: :read
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_ref, action: :by_ref, args: [:dashboard_ref]
    define :get_by_slug, action: :by_slug, args: [:slug]
    define :create_dashboard, action: :create
    define :update_dashboard, action: :update
    define :archive, action: :archive
    define :restore, action: :restore
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_ref do
      argument :dashboard_ref, :integer, allow_nil?: false
      get? true
      filter expr(dashboard_ref == ^arg(:dashboard_ref))
    end

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    read :active do
      filter expr(status != :archived)
    end

    read :policy_editor_audience do
      argument :group_id, :uuid, allow_nil?: false
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 50
      prepare {PolicyEditorAudience, source: :authored}
    end

    read :policy_editor_group_access_target do
      argument :id, :uuid, allow_nil?: false
      argument :group_id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare {PolicyEditorAudience, source: :authored}
    end

    read :local_group_access_target do
      argument :id, :uuid, allow_nil?: false
      argument :group_id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare {PolicyEditorAudience, source: :authored}
    end

    create :create do
      accept @fields -- [:owner_id]

      change fn changeset, context ->
        case actor_uuid(context) do
          nil -> changeset
          owner_id -> Ash.Changeset.change_attribute(changeset, :owner_id, owner_id)
        end
      end
    end

    update :update do
      accept @fields -- [:owner_id]
    end

    update :archive do
      accept []
      change set_attribute(:status, :archived)
      change set_attribute(:archived_at, &DateTime.utc_now/0)
    end

    update :restore do
      accept []
      change set_attribute(:status, :active)
      change set_attribute(:archived_at, nil)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action([:read, :by_id, :by_ref, :by_slug, :active]) do
      forbid_unless @view_check
      authorize_if @view_all_check
      authorize_if ServiceRadar.Dashboards.Checks.ActorCanAccessDashboard
    end

    policy action([:policy_editor_audience, :policy_editor_group_access_target]) do
      forbid_unless @rbac_manage_check
      forbid_unless @share_check
      authorize_if @edit_check
      authorize_if ActorCanEditDashboard
    end

    policy action(:local_group_access_target) do
      forbid_unless @share_check
      authorize_if ActorCanEditDashboard
    end

    action_with_permission(:create, @create_check)

    policy action([:update, :restore]) do
      authorize_if @edit_check
      authorize_if ActorCanEditDashboard
    end

    action_with_permission([:archive, :destroy], @delete_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :dashboard_ref, :integer do
      allow_nil? false
      public? true
      description "Unique 7-digit dashboard reference used in user-facing routes."
      constraints min: 1_000_000, max: 9_999_999
    end

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :slug, :string do
      public? true

      description "Optional stable route alias; dashboards are always addressable by numeric reference."
    end

    attribute :owner_id, :uuid do
      public? true
    end

    attribute :visibility, :atom do
      allow_nil? false
      public? true
      default :private
      constraints one_of: [:private, :shared, :public]
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:draft, :active, :archived]
    end

    attribute :default_time_range, :string do
      allow_nil? false
      public? true
      default "last_1h"
    end

    attribute :layout, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :variables, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :archived_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :owner, ServiceRadar.Identity.User do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :owner_id
    end

    has_many :panels, ServiceRadar.Dashboards.DashboardPanel do
      destination_attribute :dashboard_id
    end

    has_many :report_schedules, ServiceRadar.Dashboards.DashboardReportSchedule do
      destination_attribute :dashboard_id
    end

    has_many :report_deliveries, ServiceRadar.Dashboards.DashboardReportDelivery do
      destination_attribute :dashboard_id
    end

    has_many :access_grants, ServiceRadar.Dashboards.DashboardAccessGrant do
      destination_attribute :dashboard_id
    end
  end

  calculations do
    calculate :policy_editor_sort_key, :string, expr(fragment("lower(?)", title))
  end

  identities do
    identity :unique_dashboard_ref, [:dashboard_ref]
    identity :unique_slug, [:slug], where: expr(not is_nil(slug))
  end

  defp actor_uuid(context) do
    with %{id: actor_id} <- AshContext.actor(context),
         {:ok, uuid} <- Ecto.UUID.cast(actor_id) do
      uuid
    else
      _ -> nil
    end
  end
end
