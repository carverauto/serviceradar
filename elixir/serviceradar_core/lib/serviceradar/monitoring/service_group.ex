defmodule ServiceRadar.Monitoring.ServiceGroup do
  @moduledoc """
  Operator-defined service target set.
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshPaperTrail.Resource]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @services_view_check {ActorHasPermission, permission: "services.view"}
  @services_create_check {ActorHasPermission, permission: "services.create"}
  @services_update_check {ActorHasPermission, permission: "services.update"}

  @fields [:name, :slug, :description, :selection_mode, :srql_query, :tags, :metadata]

  postgres do
    table "service_groups"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_slug: "service_groups_slug_idx"
  end

  state_machine do
    initial_states [:active]
    default_initial_state :active
    state_attribute :status

    transitions do
      transition :activate, from: [:disabled], to: :active
      transition :disable, from: [:active], to: :disabled
      transition :archive, from: [:active, :disabled], to: :archived
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "service_group_versions"
    mixin {ServiceRadar.Monitoring.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_slug, action: :by_slug, args: [:slug]
    define :list_active, action: :active
    define :create_group, action: :create
    define :update_group, action: :update
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    read :active do
      filter expr(status == :active)
    end

    create :create do
      accept @fields
    end

    update :update do
      accept List.delete(@fields, :slug)
    end

    update :activate do
      accept []
      change transition_state(:active)
    end

    update :disable do
      accept []
      change transition_state(:disabled)
    end

    update :archive do
      accept []
      change transition_state(:archived)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_type_with_permission(:read, @services_view_check)
    action_type_with_permission(:create, @services_create_check)
    action_with_permission([:update, :activate, :disable, :archive], @services_update_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true

    attribute :selection_mode, :atom do
      allow_nil? false
      public? true
      default :explicit
      constraints one_of: [:explicit, :srql, :tag, :import_batch, :mixed]
    end

    attribute :srql_query, :string, allow_nil?: true, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :active
      constraints one_of: [:active, :disabled, :archived]
    end

    attribute :tags, :map do
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
    has_many :memberships, ServiceRadar.Monitoring.ServiceGroupMembership do
      destination_attribute :service_group_id
      public? true
    end

    has_many :monitoring_bindings, ServiceRadar.Monitoring.MonitoringBinding do
      destination_attribute :service_group_id
      public? true
    end
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
