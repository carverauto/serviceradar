defmodule ServiceRadar.Monitoring.LatestCheckState do
  @moduledoc """
  Current state cache for one materialized check instance.
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @services_view_check {ActorHasPermission, permission: "services.view"}
  @services_run_check {ActorHasPermission, permission: "services.run"}

  @fields [
    :check_instance_id,
    :monitored_service_id,
    :monitoring_binding_id,
    :device_uid,
    :agent_id,
    :vantage_kind,
    :vantage_id,
    :status,
    :previous_status,
    :status_changed_at,
    :last_observed_at,
    :response_time_ms,
    :summary,
    :details,
    :metrics,
    :consecutive_failures,
    :event_emitted_at,
    :alert_id
  ]

  postgres do
    table "latest_check_states"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_check_instance: "latest_check_states_check_instance_idx"
  end

  code_interface do
    define :get_by_check_instance, action: :by_check_instance, args: [:check_instance_id]
    define :list_by_service, action: :by_service, args: [:monitored_service_id]
    define :record_state, action: :record
  end

  actions do
    defaults [:read]

    read :by_check_instance do
      argument :check_instance_id, :uuid, allow_nil?: false
      get? true
      filter expr(check_instance_id == ^arg(:check_instance_id))
    end

    read :by_service do
      argument :monitored_service_id, :uuid, allow_nil?: false
      filter expr(monitored_service_id == ^arg(:monitored_service_id))
    end

    create :record do
      upsert? true
      upsert_identity :unique_check_instance
      upsert_fields List.delete(@fields, :check_instance_id) ++ [:updated_at]
      accept @fields
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_type_with_permission(:read, @services_view_check)
    action_with_permission(:record, @services_run_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :check_instance_id, :uuid, allow_nil?: false, public?: true
    attribute :monitored_service_id, :uuid, allow_nil?: true, public?: true
    attribute :monitoring_binding_id, :uuid, allow_nil?: true, public?: true
    attribute :device_uid, :string, allow_nil?: true, public?: true
    attribute :agent_id, :string, allow_nil?: true, public?: true

    attribute :vantage_kind, :atom do
      allow_nil? false
      public? true
      default :agent
      constraints one_of: [:agent, :gateway, :control_plane, :external]
    end

    attribute :vantage_id, :string, allow_nil?: true, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :unknown
      constraints one_of: [:ok, :warning, :critical, :unknown]
    end

    attribute :previous_status, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:ok, :warning, :critical, :unknown]
    end

    attribute :status_changed_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :last_observed_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :response_time_ms, :integer, allow_nil?: true, public?: true
    attribute :summary, :string, allow_nil?: true, public?: true

    attribute :details, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :metrics, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :consecutive_failures, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :event_emitted_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :alert_id, :uuid, allow_nil?: true, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :check_instance, ServiceRadar.Monitoring.CheckInstance do
      source_attribute :check_instance_id
      destination_attribute :id
      allow_nil? false
      public? true
    end

    belongs_to :monitored_service, ServiceRadar.Monitoring.MonitoredService do
      source_attribute :monitored_service_id
      destination_attribute :id
      allow_nil? true
      public? true
    end

    belongs_to :monitoring_binding, ServiceRadar.Monitoring.MonitoringBinding do
      source_attribute :monitoring_binding_id
      destination_attribute :id
      allow_nil? true
      public? true
    end

    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_uid
      destination_attribute :uid
      allow_nil? true
      public? true
    end

    belongs_to :agent, ServiceRadar.Infrastructure.Agent do
      source_attribute :agent_id
      destination_attribute :uid
      allow_nil? true
      public? true
    end

    belongs_to :alert, ServiceRadar.Monitoring.Alert do
      source_attribute :alert_id
      destination_attribute :id
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :unique_check_instance, [:check_instance_id]
  end
end
