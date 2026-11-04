defmodule ServiceRadar.Edge.ContractCatalog do
  @moduledoc """
  Core's knowledge of each output contract it can sign and project: the authority model, the
  route, the per-record bounds, the payload message, the projector and, for a standing grant,
  the package identity its records name.

  The catalog is the release's contract registry. `ServiceRadar.Edge.ContractBundle` derives
  each contract's bundle digest, and the registry snapshot digest, from these entries alone, and
  `ServiceRadar.Edge.ContractRegistry` records them as a signed registry epoch. Adding a contract
  is one entry here plus its projector module, and a projector module is needed only when the
  contract's destination is new.

    * `:sweep_lease` contracts are signed per lease by the sweep lease machinery.
    * `:standing_grant` contracts are issued per agent by `ServiceRadar.Edge.OutputGrants`.

  `projection_revision` is strictly monotonic per `(contract_id, contract_version)`. Any change
  to an entry at the same `contract_version`, including a revert to earlier values, and any
  change to how its records project, MUST bump it. The golden test
  (`test/serviceradar/edge/contract_bundle_golden_test.exs`) fails until the bump and the new
  digest are recorded. A change projectors cannot read alongside the old bundle MUST bump
  `contract_version` instead.
  """

  alias ServiceRadar.Edge.MetricsBatchProjection
  alias ServiceRadar.Edge.Projectors.FlowAttribution
  alias ServiceRadar.Edge.Projectors.MapperDevices
  alias ServiceRadar.Edge.Projectors.MapperInterfaces
  alias ServiceRadar.Edge.Projectors.MapperTopology
  alias ServiceRadar.Edge.Projectors.NetprobeDiscovery
  alias ServiceRadar.Edge.Projectors.OtlpRelay
  alias ServiceRadar.Edge.Projectors.ScheduledMtrTrace
  alias ServiceRadar.Edge.Projectors.SweepObservation
  alias ServiceRadar.Edge.Projectors.SyncPage
  alias ServiceRadar.Edge.Projectors.TelemetryBatch
  alias ServiceRadar.Edge.Projectors.UnleasedSweepResults
  alias ServiceRadar.Edge.Projectors.WasmPluginResult
  alias ServiceRadar.Edge.Projectors.WorkloadIdentity

  @type ref :: {String.t(), pos_integer()}
  @type entry :: %{
          required(:ref) => ref(),
          required(:authority) => :sweep_lease | :standing_grant,
          required(:payload) => module(),
          required(:projection_revision) => pos_integer(),
          required(:route_profile) => atom(),
          required(:traffic_class) => atom(),
          required(:partition_rule) => atom(),
          required(:cost_model_version) => pos_integer(),
          required(:projector) => module(),
          required(:max_projected_rows) => pos_integer(),
          required(:write_bytes_per_row) => pos_integer(),
          optional(:max_projected_write_bytes) => pos_integer(),
          optional(:package_id) => String.t()
        }

  # Every contract this release registers rides the durable bulk lane, partitioned by network
  # scope, under cost model 1.
  @durable_bulk %{
    route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
    traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
    partition_rule: :network_scope_v1,
    cost_model_version: 1
  }

  @entries [
    %{
      ref: {"serviceradar.sweep.observation", 1},
      payload: Serviceradar.Edge.V1.SweepObservationBatchV1,
      projection_revision: 1,
      authority: :sweep_lease,
      projector: SweepObservation,
      max_projected_rows: 10_000,
      write_bytes_per_row: 2_048
    },
    %{
      ref: {"serviceradar.metrics.batch", 1},
      payload: Serviceradar.Metric.V1.MetricBatch,
      projection_revision: 1,
      authority: :standing_grant,
      projector: MetricsBatchProjection,
      max_projected_rows: 10_000,
      write_bytes_per_row: 1_024,
      package_id: "serviceradar.agent.metrics"
    },
    %{
      ref: {"serviceradar.sweep.unleased_results", 1},
      payload: Serviceradar.Edge.V1.UnleasedSweepResultsBatchV1,
      projection_revision: 1,
      authority: :standing_grant,
      projector: UnleasedSweepResults,
      max_projected_rows: 10_000,
      write_bytes_per_row: 2_048,
      package_id: "serviceradar.agent.sweep_results"
    },
    %{
      ref: {"serviceradar.telemetry.batch", 1},
      payload: Serviceradar.Agent.Addon.V1.TelemetryBatch,
      projection_revision: 1,
      authority: :standing_grant,
      projector: TelemetryBatch,
      max_projected_rows: 10_000,
      write_bytes_per_row: 8_192,
      package_id: "serviceradar.agent.telemetry"
    },
    %{
      ref: {"serviceradar.mtr.scheduled_trace", 1},
      payload: Serviceradar.Edge.V1.AgentScheduledMtrTraceBatchV1,
      projection_revision: 1,
      authority: :standing_grant,
      projector: ScheduledMtrTrace,
      max_projected_rows: 1_000,
      write_bytes_per_row: 2_048,
      package_id: "serviceradar.agent.mtr"
    },
    %{
      ref: {"serviceradar.netprobe.flow_attribution", 1},
      payload: Serviceradar.Agent.Netprobe.V1.FlowAttributionEventBatch,
      projection_revision: 1,
      authority: :standing_grant,
      projector: FlowAttribution,
      max_projected_rows: 4_096,
      write_bytes_per_row: 983_029,
      package_id: "serviceradar.agent.flow_attribution"
    },
    %{
      ref: {"serviceradar.otlp.relay", 1},
      payload: Serviceradar.Agent.Addon.V1.OtlpRelayFrame,
      projection_revision: 1,
      authority: :standing_grant,
      projector: OtlpRelay,
      max_projected_rows: 1_024,
      write_bytes_per_row: 512,
      max_projected_write_bytes: 524_288,
      package_id: "serviceradar.agent.otlp_relay"
    },
    %{
      ref: {"serviceradar.plugin_results.batch", 1},
      payload: Serviceradar.Edge.V1.WasmPluginResultBatchV1,
      projection_revision: 1,
      authority: :standing_grant,
      projector: WasmPluginResult,
      max_projected_rows: 10_000,
      write_bytes_per_row: 16_384,
      package_id: "serviceradar.agent.plugin_results"
    },
    %{
      ref: {"serviceradar.mapper.devices.batch", 1},
      payload: Serviceradar.Edge.V1.MapperDeviceBatchV1,
      projection_revision: 1,
      authority: :standing_grant,
      projector: MapperDevices,
      max_projected_rows: 10_000,
      write_bytes_per_row: 16_384,
      package_id: "serviceradar.agent.mapper"
    },
    %{
      ref: {"serviceradar.mapper.interfaces.batch", 1},
      payload: Serviceradar.Edge.V1.MapperInterfaceBatchV1,
      projection_revision: 1,
      authority: :standing_grant,
      projector: MapperInterfaces,
      max_projected_rows: 10_000,
      write_bytes_per_row: 8_192,
      package_id: "serviceradar.agent.mapper"
    },
    %{
      ref: {"serviceradar.mapper.topology.batch", 1},
      payload: Serviceradar.Edge.V1.MapperTopologyBatchV1,
      projection_revision: 1,
      authority: :standing_grant,
      projector: MapperTopology,
      max_projected_rows: 10_000,
      write_bytes_per_row: 8_192,
      package_id: "serviceradar.agent.mapper"
    },
    %{
      ref: {"serviceradar.netprobe.discovery.batch", 1},
      payload: Serviceradar.Edge.V1.NetprobeDiscoveryBatchV1,
      projection_revision: 1,
      authority: :standing_grant,
      projector: NetprobeDiscovery,
      max_projected_rows: 10_000,
      write_bytes_per_row: 8_192,
      package_id: "serviceradar.agent.netprobe"
    },
    %{
      ref: {"serviceradar.sync.page.batch", 1},
      payload: Serviceradar.Edge.V1.SyncPageBatchV1,
      projection_revision: 1,
      authority: :standing_grant,
      projector: SyncPage,
      max_projected_rows: 10_000,
      write_bytes_per_row: 16_384,
      package_id: "serviceradar.agent.sync"
    },
    %{
      ref: {"serviceradar.workload_identity.snapshot", 1},
      payload: Serviceradar.Edge.V1.WorkloadIdentitySnapshotV1,
      projection_revision: 1,
      authority: :standing_grant,
      projector: WorkloadIdentity,
      max_projected_rows: 10_000,
      write_bytes_per_row: 8_192,
      package_id: "serviceradar.agent.workload_identity"
    }
  ]

  @entries Enum.map(@entries, &Map.merge(@durable_bulk, &1))
  @by_ref Map.new(@entries, &{&1.ref, &1})

  @doc "Every catalog entry, in catalog order."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "The catalog entry of a contract."
  @spec fetch(ref()) :: {:ok, entry()} | :error
  def fetch(ref), do: Map.fetch(@by_ref, ref)

  @doc "The projector of a contract."
  @spec projector(ref()) :: {:ok, module()} | :error
  def projector(ref) do
    with {:ok, entry} <- fetch(ref), do: {:ok, entry.projector}
  end

  @doc "Every contract core issues standing grants for, in catalog order."
  @spec standing_grant_refs() :: [ref()]
  def standing_grant_refs do
    for %{authority: :standing_grant, ref: ref} <- @entries, do: ref
  end
end
