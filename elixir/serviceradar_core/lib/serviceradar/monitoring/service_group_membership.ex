defmodule ServiceRadar.Monitoring.ServiceGroupMembership do
  @moduledoc """
  Membership edge between a service group and a monitored service.
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @services_view_check {ActorHasPermission, permission: "services.view"}
  @services_create_check {ActorHasPermission, permission: "services.create"}
  @services_update_check {ActorHasPermission, permission: "services.update"}

  @fields [:service_group_id, :monitored_service_id, :source, :metadata]

  postgres do
    table "service_group_memberships"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :service_group, on_delete: :delete
      reference :monitored_service, on_delete: :delete
    end

    identity_index_names unique_group_service: "service_group_memberships_group_service_idx"
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "service_group_membership_versions"
    mixin {ServiceRadar.Monitoring.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :add_service, action: :create
    define :list_by_group, action: :by_group, args: [:service_group_id]
    define :list_by_service, action: :by_service, args: [:monitored_service_id]
  end

  actions do
    defaults [:read]

    read :by_group do
      argument :service_group_id, :uuid, allow_nil?: false
      filter expr(service_group_id == ^arg(:service_group_id))
    end

    read :by_service do
      argument :monitored_service_id, :uuid, allow_nil?: false
      filter expr(monitored_service_id == ^arg(:monitored_service_id))
    end

    create :create do
      upsert? true
      upsert_identity :unique_group_service
      accept @fields
    end

    update :update do
      accept [:source, :metadata]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_type_with_permission(:read, @services_view_check)
    action_type_with_permission(:create, @services_create_check)
    action_type_with_permission(:update, @services_update_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :service_group_id, :uuid, allow_nil?: false, public?: true
    attribute :monitored_service_id, :uuid, allow_nil?: false, public?: true

    attribute :source, :atom do
      allow_nil? false
      public? true
      default :explicit
      constraints one_of: [:explicit, :srql, :tag, :import_batch, :backfill]
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
    belongs_to :service_group, ServiceRadar.Monitoring.ServiceGroup do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :service_group_id
    end

    belongs_to :monitored_service, ServiceRadar.Monitoring.MonitoredService do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :monitored_service_id
    end
  end

  identities do
    identity :unique_group_service, [:service_group_id, :monitored_service_id]
  end
end
