defmodule ServiceRadar.Scans.ScanRun do
  @moduledoc """
  One user-initiated ad-hoc scan.

  Captures the chosen egress agent, requested modes (`icmp`/`tcp`/`mtr`),
  ports, normalized target list, options, and lifecycle status. A ScanRun
  fans out on the agent command bus: ICMP/TCP via a `scan.run_adhoc`
  command, MTR via the existing `mtr.bulk_run` command tagged with this
  run's id. Per-target results are stored separately (`ScanResult` +
  `mtr_traces`) keyed on `scan_run_id`.

  The table is Ash-managed. Status transitions are driven by the dispatch
  and ingestion pipeline using a system actor (covered by `system_bypass`).
  """

  use Ash.Resource,
    domain: ServiceRadar.Scans,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @scans_read_check {ActorHasPermission, permission: "scans.read"}
  @scans_execute_check {ActorHasPermission, permission: "scans.execute"}

  @statuses [:pending, :running, :partial, :completed, :failed]

  @create_fields [
    :agent_id,
    :gateway_id,
    :partition,
    :modes,
    :ports,
    :targets,
    :target_count,
    :options,
    :requested_by
  ]

  @update_fields [
    :status,
    :scan_command_id,
    :mtr_command_id,
    :hosts_up,
    :ports_open,
    :error,
    :started_at,
    :finished_at
  ]

  postgres do
    table "adhoc_scan_runs"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index [:agent_id]
      index [:status]
      index [:inserted_at]
    end
  end

  code_interface do
    define :create, action: :create
    define :get, action: :read, get_by: [:id]
    define :list_recent, action: :recent
    define :by_agent, action: :by_agent, args: [:agent_id]
    define :update_status, action: :update
  end

  actions do
    defaults [:read, :destroy]

    read :recent do
      description "Most recent scan runs first"
      prepare build(sort: [inserted_at: :desc], limit: 200)
    end

    read :by_agent do
      argument :agent_id, :string, allow_nil?: false
      filter expr(agent_id == ^arg(:agent_id))
      prepare build(sort: [inserted_at: :desc])
    end

    create :create do
      description "Create a new ad-hoc scan run"
      accept @create_fields
      change set_attribute(:status, :pending)
    end

    update :update do
      description "Update run lifecycle status and counters"
      require_atomic? false
      accept @update_fields
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@scans_read_check)
    action_type_with_permission([:create, :update, :destroy], @scans_execute_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :agent_id, :string do
      allow_nil? false
      public? true
      description "Agent chosen to egress the scan"
    end

    attribute :gateway_id, :string do
      public? true
    end

    attribute :partition, :string do
      public? true
    end

    attribute :modes, {:array, ServiceRadar.Scans.ScanMode} do
      allow_nil? false
      public? true
      constraints min_length: 1
      description "Requested scan modes (icmp/tcp/mtr)"
    end

    attribute :ports, {:array, :integer} do
      allow_nil? false
      default []
      public? true
      description "TCP ports to probe (when tcp mode is requested)"
    end

    attribute :targets, {:array, :string} do
      allow_nil? false
      default []
      public? true
      description "Normalized target IPs/CIDRs"
    end

    attribute :target_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :options, :map do
      allow_nil? false
      default %{}
      public? true
      description "Scan options (timeouts, concurrency, icmp_count, mtr protocol/max_hops)"
    end

    attribute :status, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: @statuses
    end

    attribute :requested_by, :string do
      public? true
      description "User id/email that requested the scan"
    end

    attribute :scan_command_id, :string do
      public? true
      description "scan.run_adhoc command id (ICMP/TCP)"
    end

    attribute :mtr_command_id, :string do
      public? true
      description "mtr.bulk_run command id (MTR)"
    end

    attribute :hosts_up, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :ports_open, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :error, :string do
      public? true
    end

    attribute :started_at, :utc_datetime_usec do
      public? true
    end

    attribute :finished_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end
end
