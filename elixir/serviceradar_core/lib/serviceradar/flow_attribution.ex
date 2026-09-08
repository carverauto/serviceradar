defmodule ServiceRadar.FlowAttribution do
  @moduledoc """
  Persists netprobe process attributions pushed by agents and correlates them
  against collected NetFlow/sFlow in `ocsf_network_activity`.

  NetFlow remains the authoritative flow source; netprobe supplies process and
  workload context. This module intentionally stays as the public API while the
  persistence, correlation, retention, and protobuf normalization details live in
  smaller implementation modules under `ServiceRadar.FlowAttribution`.
  """

  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent
  alias ServiceRadar.FlowAttribution.Correlation
  alias ServiceRadar.FlowAttribution.EventRows
  alias ServiceRadar.FlowAttribution.Persistence
  alias ServiceRadar.FlowAttribution.Retention
  alias ServiceRadar.FlowAttribution.WorkloadBackfill

  require Logger

  @doc "Persist a batch of pushed attribution events."
  @spec persist(
          [FlowAttributionEvent.t()],
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: :ok | {:error, term()}
  def persist(events, partition_id, agent_id, opts \\ [])

  def persist(events, partition_id, agent_id, opts) when is_list(events) do
    rows =
      events
      |> Enum.map(&EventRows.from_event(&1, partition_id, agent_id))
      |> Enum.reject(&is_nil/1)

    case rows do
      [] ->
        :ok

      rows ->
        persistence = Keyword.get(opts, :persistence, &Persistence.insert_current_rows/1)

        case persistence.(rows) do
          :ok -> :ok
          {:ok, _result} -> :ok
          {:error, reason} -> persistence_error(reason)
          %Postgrex.Result{} -> :ok
          other -> persistence_error({:unexpected_persistence_result, other})
        end
    end
  rescue
    error ->
      persistence_error(error)
  end

  def persist(_events, _partition_id, _agent_id, _opts), do: :ok

  @doc """
  Correlate recent attributions with recent NetFlow and stamp matches as
  `attributed_flow`. Direction-agnostic and idempotent.
  """
  @spec correlate() :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate correlate, to: Correlation

  @doc """
  Backfill workload identity into recent current-state attribution rows.

  Workload snapshots can arrive after netprobe has already emitted a process/socket
  observation. Keeping this backfill in core preserves the clean add-on split: the
  edge does not need to replay process observations just because runtime metadata
  arrived later.
  """
  @spec backfill_current_workload_identity() :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate backfill_current_workload_identity, to: WorkloadBackfill

  @doc "Backfill recent current-state attribution rows for specific workload identity keys."
  @spec backfill_current_workload_identity([map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate backfill_current_workload_identity(rows), to: WorkloadBackfill

  @doc "Delete attributions older than the retention window."
  @spec prune() :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate prune, to: Retention

  @doc """
  Returns raw attribution staging retention in minutes.

  The value is clamped to the correlation skew so a deployment cannot discard
  observations before delayed NetFlow/IPFIX rows have a chance to match.
  """
  @spec retention_minutes() :: pos_integer()
  defdelegate retention_minutes, to: Retention

  defp persistence_error(reason) do
    Logger.warning("FlowAttribution.persist failed: #{inspect(reason)}")
    {:error, {:flow_attribution_persist_failed, reason}}
  end
end
