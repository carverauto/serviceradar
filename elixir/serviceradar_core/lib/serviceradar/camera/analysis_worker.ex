defmodule ServiceRadar.Camera.AnalysisWorker do
  @moduledoc """
  Platform-owned registry of camera analysis workers.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @mutable_fields [
    :display_name,
    :adapter,
    :endpoint_url,
    :capabilities,
    :enabled,
    :health_status,
    :health_reason,
    :last_health_transition_at,
    :last_healthy_at,
    :last_failure_at,
    :consecutive_failures,
    :headers,
    :metadata
  ]

  postgres do
    table "camera_analysis_workers"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_worker_id, action: :by_worker_id, args: [:worker_id]
    define :list_enabled, action: :enabled
    define :mark_healthy, action: :mark_healthy
    define :mark_unhealthy, action: :mark_unhealthy
    define :register_worker, action: :create
    define :update_worker, action: :update
    define :upsert_worker, action: :upsert
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_worker_id do
      argument :worker_id, :string, allow_nil?: false
      get? true
      filter expr(worker_id == ^arg(:worker_id))
    end

    read :enabled do
      filter expr(enabled == true)
      prepare build(sort: [worker_id: :asc])
    end

    update :mark_healthy do
      accept [:health_reason]

      change set_attribute(:health_status, "healthy")
      change set_attribute(:consecutive_failures, 0)
      change set_attribute(:last_health_transition_at, &DateTime.utc_now/0)
      change set_attribute(:last_healthy_at, &DateTime.utc_now/0)
      change set_attribute(:health_reason, nil)
    end

    update :mark_unhealthy do
      accept [:health_reason]

      argument :health_reason, :string do
        allow_nil? true
      end

      change set_attribute(:health_status, "unhealthy")
      change set_attribute(:last_health_transition_at, &DateTime.utc_now/0)
      change set_attribute(:last_failure_at, &DateTime.utc_now/0)
      change set_attribute(:health_reason, arg(:health_reason))
      change increment(:consecutive_failures, amount: 1)
    end

    create :create do
      accept [
        :worker_id,
        :display_name,
        :adapter,
        :endpoint_url,
        :capabilities,
        :enabled,
        :health_status,
        :health_reason,
        :last_health_transition_at,
        :last_healthy_at,
        :last_failure_at,
        :consecutive_failures,
        :headers,
        :metadata
      ]
    end

    update :update do
      accept @mutable_fields
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_worker_id

      accept [
        :worker_id,
        :display_name,
        :adapter,
        :endpoint_url,
        :capabilities,
        :enabled,
        :health_status,
        :health_reason,
        :last_health_transition_at,
        :last_healthy_at,
        :last_failure_at,
        :consecutive_failures,
        :headers,
        :metadata
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :worker_id, :string do
      allow_nil? false
      public? true
    end

    attribute :display_name, :string do
      public? true
    end

    attribute :adapter, :string do
      allow_nil? false
      public? true
      default "http"
    end

    attribute :endpoint_url, :string do
      allow_nil? false
      public? true
    end

    attribute :capabilities, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :health_status, :string do
      allow_nil? false
      public? true
      default "healthy"
    end

    attribute :health_reason, :string do
      public? true
    end

    attribute :last_health_transition_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_healthy_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_failure_at, :utc_datetime_usec do
      public? true
    end

    attribute :consecutive_failures, :integer do
      allow_nil? false
      public? true
      default 0
    end

    attribute :headers, :map do
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

  identities do
    identity :unique_worker_id, [:worker_id]
  end
end
