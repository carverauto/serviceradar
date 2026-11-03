defmodule ServiceRadar.Edge.ContractCatalog do
  @moduledoc """
  Core's knowledge of each output contract it can sign and project: the authority model, the
  per-record bounds, the projector and, for a standing grant, the package identity its records
  name.

  The installation's registry document (`ServiceRadar.Edge.ContractRegistryDocument`) decides
  which contracts are active; this catalog decides what core does with an active one. Adding a
  contract is one entry here plus its projector module, and a projector module is needed only
  when the contract's destination is new.

    * `:sweep_lease` contracts are signed per lease by the sweep lease machinery.
    * `:standing_grant` contracts are issued per agent by `ServiceRadar.Edge.OutputGrants`.
  """

  alias ServiceRadar.Edge.MetricsBatchProjection
  alias ServiceRadar.Edge.Projectors.ScheduledMtrTrace
  alias ServiceRadar.Edge.Projectors.SweepObservation
  alias ServiceRadar.Edge.Projectors.TelemetryBatch
  alias ServiceRadar.Edge.Projectors.UnleasedSweepResults

  @type ref :: {String.t(), pos_integer()}
  @type entry :: %{
          required(:ref) => ref(),
          required(:authority) => :sweep_lease | :standing_grant,
          required(:projector) => module(),
          required(:max_projected_rows) => pos_integer(),
          required(:write_bytes_per_row) => pos_integer(),
          optional(:package_id) => String.t()
        }

  @entries [
    %{
      ref: {"serviceradar.sweep.observation", 1},
      authority: :sweep_lease,
      projector: SweepObservation,
      max_projected_rows: 10_000,
      write_bytes_per_row: 2_048
    },
    %{
      ref: {"serviceradar.metrics.batch", 1},
      authority: :standing_grant,
      projector: MetricsBatchProjection,
      max_projected_rows: 10_000,
      write_bytes_per_row: 1_024,
      package_id: "serviceradar.agent.metrics"
    },
    %{
      ref: {"serviceradar.sweep.unleased_results", 1},
      authority: :standing_grant,
      projector: UnleasedSweepResults,
      max_projected_rows: 10_000,
      write_bytes_per_row: 2_048,
      package_id: "serviceradar.agent.sweep_results"
    },
    %{
      ref: {"serviceradar.telemetry.batch", 1},
      authority: :standing_grant,
      projector: TelemetryBatch,
      max_projected_rows: 10_000,
      write_bytes_per_row: 8_192,
      package_id: "serviceradar.agent.telemetry"
    },
    %{
      ref: {"serviceradar.mtr.scheduled_trace", 1},
      authority: :standing_grant,
      projector: ScheduledMtrTrace,
      max_projected_rows: 1_000,
      write_bytes_per_row: 2_048,
      package_id: "serviceradar.agent.mtr"
    }
  ]

  @by_ref Map.new(@entries, &{&1.ref, &1})

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
