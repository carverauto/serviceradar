defmodule ServiceRadar.Dashboards.DashboardInstanceAccessGrant do
  @moduledoc """
  Explicit user or group access grant for a package dashboard instance.
  """

  use Ash.Resource,
    domain: ServiceRadar.Dashboards,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Dashboards.Changes.RequireGroupAccessBoundary
  alias ServiceRadar.Dashboards.Checks.ActorCanEditDashboardInstanceChild
  alias ServiceRadar.Dashboards.Checks.ActorCanEditDashboardInstanceTarget
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_all_check {ActorHasPermission, permission: "dashboards.packages.view_all"}
  @share_check {ActorHasPermission, permission: "dashboards.packages.share"}

  @fields [
    :dashboard_instance_id,
    :subject_type,
    :subject_user_id,
    :subject_group_id,
    :access,
    :granted_by_id,
    :metadata
  ]

  postgres do
    table "dashboard_instance_access_grants"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false

    identity_wheres_to_sql unique_user_grant:
                             "subject_type = 'user' AND subject_user_id IS NOT NULL",
                           unique_group_grant:
                             "subject_type = 'group' AND subject_group_id IS NOT NULL"

    references do
      reference :dashboard_instance, on_delete: :delete
      reference :subject_user, on_delete: :delete
      reference :subject_group, on_delete: :delete
      reference :granted_by, on_delete: :nilify
    end
  end

  paper_trail do
    primary_key_type :uuid
    table_name "dashboard_instance_access_grant_versions"
    mixin {ServiceRadar.Dashboards.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    reference_source? false
    create_version_on_destroy? true
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :list, action: :read
    define :create_user_grant, action: :create
    define :update_grant, action: :update
  end

  actions do
    defaults [:read]

    read :for_instance do
      argument :dashboard_instance_id, :uuid, allow_nil?: false
      filter expr(dashboard_instance_id == ^arg(:dashboard_instance_id))
    end

    create :create do
      accept @fields -- [:subject_type, :subject_group_id]
      change set_attribute(:subject_type, :user)
      validate fn changeset, _context -> validate_subject(changeset, :user) end
      upsert? true
      upsert_identity :unique_user_grant
      upsert_fields [:access, :granted_by_id, :metadata, :updated_at]
    end

    create :create_group do
      accept @fields -- [:subject_type, :subject_user_id]
      change set_attribute(:subject_type, :group)
      validate fn changeset, _context -> validate_subject(changeset, :group) end
      upsert? true
      upsert_identity :unique_group_grant
      upsert_fields [:access, :granted_by_id, :metadata, :updated_at]
      validate RequireGroupAccessBoundary
    end

    create :ensure_group_view do
      accept [:dashboard_instance_id, :subject_group_id, :granted_by_id]
      change set_attribute(:subject_type, :group)
      change set_attribute(:access, :view)
      validate fn changeset, _context -> validate_subject(changeset, :group) end
      validate RequireGroupAccessBoundary
      upsert? true
      upsert_identity :unique_group_grant
      upsert_condition expr(access != :edit)
      upsert_fields [:access, :granted_by_id, :updated_at]
      return_skipped_upsert? true
    end

    create :set_group_access do
      accept [
        :dashboard_instance_id,
        :subject_group_id,
        :access,
        :granted_by_id,
        :metadata
      ]

      change set_attribute(:subject_type, :group)
      validate fn changeset, _context -> validate_subject(changeset, :group) end
      validate RequireGroupAccessBoundary
      upsert? true
      upsert_identity :unique_group_grant
      upsert_fields [:access, :granted_by_id, :metadata, :updated_at]
      return_skipped_upsert? true
    end

    update :update do
      accept [:access, :metadata]
      validate {RequireGroupAccessBoundary, group_only?: false}
    end

    destroy :destroy do
      primary? true
      validate {RequireGroupAccessBoundary, group_only?: false}
    end

    destroy :revoke_group_view do
      validate RequireGroupAccessBoundary
    end

    destroy :revoke_group_access do
      validate RequireGroupAccessBoundary
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_all_check
      authorize_if @share_check
      authorize_if ActorCanEditDashboardInstanceChild
    end

    policy action([:create, :create_group, :ensure_group_view, :set_group_access]) do
      authorize_if @share_check
      authorize_if ActorCanEditDashboardInstanceTarget
    end

    policy action([:update, :destroy, :revoke_group_view, :revoke_group_access]) do
      authorize_if @share_check
      authorize_if ActorCanEditDashboardInstanceChild
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :dashboard_instance_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :subject_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:user, :group]
    end

    attribute :subject_user_id, :uuid do
      public? true
    end

    attribute :subject_group_id, :uuid do
      public? true
    end

    attribute :access, :atom do
      allow_nil? false
      public? true
      default :view
      constraints one_of: [:view, :edit]
    end

    attribute :granted_by_id, :uuid do
      public? true
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
    belongs_to :dashboard_instance, ServiceRadar.Dashboards.DashboardInstance do
      allow_nil? false
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :dashboard_instance_id
    end

    belongs_to :subject_user, User do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :subject_user_id
    end

    belongs_to :subject_group, ServiceRadar.Identity.UserGroup do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :subject_group_id
    end

    belongs_to :granted_by, User do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :granted_by_id
    end
  end

  identities do
    identity :unique_user_grant, [:dashboard_instance_id, :subject_type, :subject_user_id],
      where: expr(subject_type == :user and not is_nil(subject_user_id))

    identity :unique_group_grant, [:dashboard_instance_id, :subject_type, :subject_group_id],
      where: expr(subject_type == :group and not is_nil(subject_group_id))
  end

  defp validate_subject(changeset, :user) do
    user_id = Ash.Changeset.get_attribute(changeset, :subject_user_id)

    if user_id do
      :ok
    else
      {:error, field: :subject_user_id, message: "is required for user grants"}
    end
  end

  defp validate_subject(changeset, :group) do
    group_id = Ash.Changeset.get_attribute(changeset, :subject_group_id)

    if group_id do
      :ok
    else
      {:error, field: :subject_group_id, message: "is required for group grants"}
    end
  end
end
