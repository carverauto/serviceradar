defmodule ServiceRadar.Dashboards.DashboardAccessGrant do
  @moduledoc """
  Explicit user or group access grant for an authored dashboard.
  """

  use Ash.Resource,
    domain: ServiceRadar.Dashboards,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_all_check {ActorHasPermission, permission: "analytics.dashboards.view_all"}
  @share_check {ActorHasPermission, permission: "analytics.dashboards.share"}
  @fields [
    :dashboard_id,
    :subject_type,
    :subject_user_id,
    :subject_group_id,
    :access,
    :granted_by_id,
    :metadata
  ]

  postgres do
    table("dashboard_access_grants")
    repo(ServiceRadar.Repo)
    schema("platform")
    migrate?(false)

    references do
      reference(:dashboard, on_delete: :delete)
      reference(:subject_user, on_delete: :delete)
      reference(:subject_group, on_delete: :delete)
      reference(:granted_by, on_delete: :nilify)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept(@fields)
      upsert?(true)
      upsert_identity(:unique_user_grant)
      upsert_fields([:access, :granted_by_id, :metadata, :updated_at])
    end

    create :create_group do
      accept(@fields)
      upsert?(true)
      upsert_identity(:unique_group_grant)
      upsert_fields([:access, :granted_by_id, :metadata, :updated_at])
    end

    update :update do
      accept([:access, :metadata])
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if(@view_all_check)
      authorize_if(@share_check)
    end

    action_type_with_permission([:create, :update, :destroy], @share_check)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :dashboard_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :subject_type, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:user, :group])
    end

    attribute :subject_user_id, :uuid do
      public?(true)
    end

    attribute :subject_group_id, :uuid do
      public?(true)
    end

    attribute :access, :atom do
      allow_nil?(false)
      public?(true)
      default(:view)
      constraints(one_of: [:view, :edit])
    end

    attribute :granted_by_id, :uuid do
      public?(true)
    end

    attribute :metadata, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :dashboard, ServiceRadar.Dashboards.AuthoredDashboard do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
      define_attribute?(false)
      source_attribute(:dashboard_id)
    end

    belongs_to :subject_user, ServiceRadar.Identity.User do
      attribute_writable?(true)
      public?(true)
      define_attribute?(false)
      source_attribute(:subject_user_id)
    end

    belongs_to :subject_group, ServiceRadar.Identity.UserGroup do
      attribute_writable?(true)
      public?(true)
      define_attribute?(false)
      source_attribute(:subject_group_id)
    end

    belongs_to :granted_by, ServiceRadar.Identity.User do
      attribute_writable?(true)
      public?(true)
      define_attribute?(false)
      source_attribute(:granted_by_id)
    end
  end

  identities do
    identity(:unique_user_grant, [:dashboard_id, :subject_type, :subject_user_id],
      where: expr(subject_type == :user and not is_nil(subject_user_id))
    )

    identity(:unique_group_grant, [:dashboard_id, :subject_type, :subject_group_id],
      where: expr(subject_type == :group and not is_nil(subject_group_id))
    )
  end
end
