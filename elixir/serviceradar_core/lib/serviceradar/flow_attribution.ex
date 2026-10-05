defmodule ServiceRadar.FlowAttribution do
  @moduledoc """
  Netprobe process attribution for collected NetFlow/sFlow.

  Agents push process/socket observations; core publishes them on JetStream
  (`ServiceRadar.FlowAttribution.Observations`) and EventWriter loads them into
  the StarRocks table `flow_process_attribution_observations`. The correlator
  matches recent unattributed flows in `ocsf_network_activity` against those
  observations in the warehouse and stamps the matches as `attributed_flow`.

  NetFlow remains the authoritative flow source; netprobe supplies process and
  workload context. Flows are warehouse-only, so attribution requires StarRocks:
  without it observations are not stored anywhere, the correlator does not run,
  and `health/0` reports `attribution_disabled: :starrocks_required`.
  """

  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent
  alias ServiceRadar.Analytics.StarRocks.Readers
  alias ServiceRadar.FlowAttribution.Correlation
  alias ServiceRadar.FlowAttribution.EventRows
  alias ServiceRadar.FlowAttribution.Observations

  require Logger

  @doc """
  Publish a batch of pushed attribution events as observations.

  Returns `:ok` without publishing when attribution is disabled (no StarRocks),
  so the agent's batch is acknowledged and dropped rather than retried forever.

  Options: `:enabled` overrides `enabled?/0`; `:publish` is passed to
  `Observations.publish/2`.
  """
  @spec publish_observations(
          [FlowAttributionEvent.t()],
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: :ok | {:error, term()}
  def publish_observations(events, partition_id, agent_id, opts \\ [])

  def publish_observations(events, partition_id, agent_id, opts) when is_list(events) do
    if Keyword.get_lazy(opts, :enabled, &enabled?/0) do
      events
      |> Enum.map(&EventRows.from_event(&1, partition_id, agent_id))
      |> Enum.reject(&is_nil/1)
      |> publish_rows(opts)
    else
      :ok
    end
  end

  def publish_observations(_events, _partition_id, _agent_id, _opts), do: :ok

  defp publish_rows([], _opts), do: :ok

  defp publish_rows(rows, opts) do
    case Observations.publish(rows, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("FlowAttribution observation publish failed: #{inspect(reason)}")
        {:error, {:flow_attribution_publish_failed, reason}}
    end
  end

  @doc """
  Correlate recent observations with recent NetFlow and stamp matches as
  `attributed_flow`. Direction-agnostic and idempotent.
  """
  @spec correlate() :: {:ok, non_neg_integer() | :not_applicable} | {:error, term()}
  defdelegate correlate, to: Correlation

  @doc "Whether attribution runs: flows, and so observations, live in StarRocks."
  @spec enabled?() :: boolean()
  def enabled?, do: Readers.backend(:flows) == :starrocks

  @doc "The attribution health surface."
  @spec health() ::
          %{enabled: true} | %{enabled: false, attribution_disabled: :starrocks_required}
  def health do
    if enabled?() do
      %{enabled: true}
    else
      %{enabled: false, attribution_disabled: :starrocks_required}
    end
  end
end
