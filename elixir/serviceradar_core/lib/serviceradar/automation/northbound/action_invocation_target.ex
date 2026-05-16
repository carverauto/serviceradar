defmodule ServiceRadar.Automation.Northbound.ActionInvocationTarget do
  @moduledoc """
  Per-target result for a northbound action invocation.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Northbound,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Automation.Northbound.Changes.RedactTargetResult
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "northbound.actions.view"}

  postgres do
    table "northbound_action_invocation_targets"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :invocation, on_delete: :delete
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_for_invocation, action: :for_invocation, args: [:invocation_id]
    define :create_target, action: :create
    define :record_result, action: :record_result
  end

  actions do
    defaults [:destroy]

    read :read

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :for_invocation do
      argument :invocation_id, :uuid, allow_nil?: false
      filter expr(invocation_id == ^arg(:invocation_id))
    end

    create :create do
      accept [
        :invocation_id,
        :target_kind,
        :device_uid,
        :interface_uid,
        :target_snapshot,
        :status,
        :result,
        :external_correlation_id,
        :started_at,
        :completed_at
      ]

      change RedactTargetResult
    end

    update :record_result do
      accept [:status, :result, :external_correlation_id, :started_at, :completed_at]
      change RedactTargetResult
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :for_invocation], @view_check)
    # Mutations are driven by the action dispatcher/provider.
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :invocation_id, :uuid, allow_nil?: false, public?: true

    attribute :target_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:device, :interface, :event]
    end

    attribute :device_uid, :string, allow_nil?: true, public?: true
    attribute :interface_uid, :string, allow_nil?: true, public?: true

    attribute :target_snapshot, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :running, :succeeded, :failed, :skipped, :suppressed]
    end

    attribute :result, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :external_correlation_id, :string, allow_nil?: true, public?: true
    attribute :started_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :completed_at, :utc_datetime_usec, allow_nil?: true, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :invocation, ServiceRadar.Automation.Northbound.ActionInvocation do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :invocation_id
    end
  end
end
