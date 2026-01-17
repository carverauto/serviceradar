defmodule ServiceRadar.SweepJobs.SweepHostResult do
  @moduledoc """
  Per-host results from sweep executions.

  Each time a host is scanned during a sweep execution, a result record is created
  to track the outcome. This provides detailed visibility into sweep performance
  and network availability.

  ## Attributes

  - `ip`: IP address that was scanned
  - `hostname`: Resolved hostname (if available)
  - `status`: Result status (:available, :unavailable, :timeout, :error)
  - `response_time_ms`: Response time in milliseconds
  - `sweep_modes_results`: Map of mode -> result for each scan mode used
  - `open_ports`: List of open ports discovered
  - `error_message`: Error details if status is :error

  ## Usage

      # Record a successful scan result
      SweepHostResult
      |> Ash.Changeset.for_create(:create, %{
        execution_id: execution.id,
        ip: "192.168.1.1",
        status: :available,
        response_time_ms: 5,
        open_ports: [22, 80]
      })
      |> Ash.create!()
  """

  use Ash.Resource,
    domain: ServiceRadar.SweepJobs,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "sweep_host_results"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:execution_id],
        name: "sweep_host_results_execution_idx"

      index [:ip],
        name: "sweep_host_results_ip_idx"

      index [:status],
        name: "sweep_host_results_status_idx"
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :execution_id,
        :ip,
        :hostname,
        :status,
        :response_time_ms,
        :sweep_modes_results,
        :open_ports,
        :error_message,
        :device_id
      ]

    end

    create :bulk_create do
      description "Bulk create host results from sweep"

      accept [
        :execution_id,
        :ip,
        :hostname,
        :status,
        :response_time_ms,
        :sweep_modes_results,
        :open_ports,
        :error_message,
        :device_id
      ]

    end

    read :by_execution do
      argument :execution_id, :uuid, allow_nil?: false

      filter expr(execution_id == ^arg(:execution_id))

      prepare build(sort: [ip: :asc])
    end

    read :available_by_execution do
      argument :execution_id, :uuid, allow_nil?: false

      filter expr(execution_id == ^arg(:execution_id) and status == :available)
    end

    read :failed_by_execution do
      argument :execution_id, :uuid, allow_nil?: false

      filter expr(execution_id == ^arg(:execution_id) and status in [:unavailable, :timeout, :error])
    end

    read :by_ip do
      argument :ip, :string, allow_nil?: false

      filter expr(ip == ^arg(:ip))

      prepare build(sort: [inserted_at: :desc])
    end

    read :recent_for_device do
      argument :device_id, :uuid, allow_nil?: false
      argument :limit, :integer, default: 10

      filter expr(device_id == ^arg(:device_id))

      prepare build(sort: [inserted_at: :desc])
      prepare build(limit: arg(:limit))
    end
  end

  policies do
    # System actors can do anything

    # System actors can perform all operations (schema isolation via search_path)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # System can create results (from sweep execution)
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # All authenticated users can read results
    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :ip, :string do
      allow_nil? false
      public? true
      description "IP address that was scanned"
    end

    attribute :hostname, :string do
      allow_nil? true
      public? true
      description "Resolved hostname (if available)"
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:available, :unavailable, :timeout, :error]
      description "Scan result status"
    end

    attribute :response_time_ms, :integer do
      allow_nil? true
      public? true
      description "Response time in milliseconds"
    end

    attribute :sweep_modes_results, :map do
      allow_nil? false
      public? true
      default %{}
      description "Results per sweep mode (e.g., %{icmp: :success, tcp: :failed})"
    end

    attribute :open_ports, {:array, :integer} do
      allow_nil? false
      public? true
      default []
      description "List of open TCP ports discovered"
    end

    attribute :error_message, :string do
      allow_nil? true
      public? true
      description "Error details if status is :error"
    end

    attribute :execution_id, :uuid do
      allow_nil? false
      public? true
      description "The sweep execution this result belongs to"
    end

    attribute :device_id, :uuid do
      allow_nil? true
      public? true
      description "Associated device ID (if matched to inventory)"
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :execution, ServiceRadar.SweepJobs.SweepGroupExecution do
      allow_nil? false
      define_attribute? false
      destination_attribute :id
      source_attribute :execution_id
    end
  end

  calculations do
    calculate :is_available, :boolean, expr(status == :available)
  end
end
