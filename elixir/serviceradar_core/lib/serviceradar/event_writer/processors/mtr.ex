defmodule ServiceRadar.EventWriter.Processors.Mtr do
  @moduledoc """
  Persists MTR trace results from the `mtr.results.>` stream.

  `ServiceRadar.Observability.MtrResultPublisher` publishes one message per
  trace for scheduled checks, on-demand runs and bulk jobs, and
  `ServiceRadar.EventWriter.Processors.AdhocScan` hands over the traces of
  ad-hoc scans. This module is the only writer of MTR traces and hops, and
  stores them in exactly one backend (`store/3`):

    * StarRocks enabled (`analytics.starrocks.enabled`): the warehouse tables
      `mtr_traces` and `mtr_hops`, and nothing in CNPG. A failed load is an
      error, so JetStream redelivers; it never falls back to CNPG.
    * StarRocks disabled: CNPG, through
      `ServiceRadar.Observability.MtrMetricsIngestor`.

  Both backends store the rows `MtrMetricsIngestor.rows/2` builds, and both
  then project the traces into the graph (`MtrGraph.project_traces/2`). A
  stored trace is announced on `ServiceRadar.Observability.MtrPubSub` when the
  message asks for that, so a page waiting on the trace refreshes after it is
  stored rather than before.

  Every message carries a `trace_uuid`, and a hop's id is derived from it and
  the hop's position. CNPG skips traces already stored under their id; the
  warehouse tables are keyed by id, so a reload upserts the same rows. Either
  way a batch that failed part way and is redelivered does not duplicate the
  traces that did land.

  Every message in a batch is attempted. A result that can never be stored
  (`:missing_target_ip`, `:invalid_payload`) is logged and dropped, since
  redelivery cannot fix it. Any other failure is returned after the whole batch
  ran, so JetStream redelivers.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Observability.MtrGraph
  alias ServiceRadar.Observability.MtrMetricsIngestor
  alias ServiceRadar.Observability.MtrPubSub

  require Logger

  @impl true
  def table_name, do: "mtr_traces"

  @permanent_errors [:missing_target_ip, :invalid_payload]

  @impl true
  def process_batch(messages), do: process_batch(messages, [])

  @doc false
  def process_batch(messages, opts) do
    parsed =
      messages
      |> Enum.map(&parse_message/1)
      |> Enum.reject(&is_nil/1)

    case persist_all(parsed, opts) do
      :ok -> {:ok, length(parsed)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Persists parsed results one at a time (see `persist/2`).

  Returns `:ok` when each was stored or can never be, otherwise the first
  other failure, after every result was attempted.
  """
  @spec persist_all([map()], keyword()) :: :ok | {:error, term()}
  def persist_all(parsed, opts \\ []) when is_list(parsed) do
    parsed
    |> Enum.map(&(&1 |> persist(opts) |> classify()))
    |> Enum.find(:ok, &match?({:error, _}, &1))
  end

  defp classify(:ok), do: :ok

  defp classify({:error, reason}) when reason in @permanent_errors do
    Logger.warning("Dropping MTR result that can never be stored", reason: inspect(reason))
    :ok
  end

  defp classify({:error, _reason} = error), do: error

  @impl true
  def parse_message(%{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"payload" => %{} = payload} = envelope} ->
        %{
          payload: payload,
          status: status(Map.get(envelope, "status")),
          broadcast: Map.get(envelope, "broadcast")
        }

      {:ok, _other} ->
        Logger.warning("Dropping MTR result message without a payload")
        nil

      {:error, reason} ->
        Logger.warning("Dropping undecodable MTR result message: #{inspect(reason)}")
        nil
    end
  end

  def parse_message(_message), do: nil

  @doc false
  def persist(%{payload: payload, status: status} = parsed, opts \\ []) do
    case store(payload, status, opts) do
      :ok ->
        announce(Map.get(parsed, :broadcast), opts)
        :ok

      {:error, reason} = error ->
        Logger.warning("MTR result persist failed", reason: inspect(reason))
        error
    end
  end

  @doc """
  Stores one ingest payload (`%{"results" => [...]}` or a single result) in
  the active telemetry backend and projects it into the graph.

  Options (tests):

    * `:starrocks_enabled` - the backend switch; defaults to
      `Destination.enabled?/0`
    * `:ingest` - the CNPG writer, `(payload, status, opts -> :ok | {:error, term})`
    * `:rows` - the row builder, `(payload, status -> {:ok, built} | {:error, term})`
    * `:load` - the warehouse loader, `(dataset, rows -> {:ok, map} | {:error, term})`
    * `:project` - the graph projection, `(results, status -> term)`
  """
  @spec store(map() | list(), map(), keyword()) :: :ok | {:error, term()}
  def store(payload, status, opts \\ []) do
    if Keyword.get_lazy(opts, :starrocks_enabled, &Destination.enabled?/0) do
      store_warehouse(payload, status, opts)
    else
      ingest = Keyword.get(opts, :ingest, &MtrMetricsIngestor.ingest/3)
      ingest.(payload, status, skip_existing: true)
    end
  end

  # Traces load before their hops. A hop load that fails leaves the traces in
  # place; the redelivery upserts them again with the same keys and then loads
  # the hops.
  defp store_warehouse(payload, status, opts) do
    build = Keyword.get(opts, :rows, &MtrMetricsIngestor.rows/2)
    load = Keyword.get(opts, :load, &Destination.persist_warehouse/2)
    project = Keyword.get(opts, :project, &MtrGraph.project_traces/2)

    with {:ok, %{results: results, traces: traces, hops: hops}} <- build.(payload, status),
         {:ok, _loaded} <- load.(:mtr_traces, traces),
         {:ok, _loaded} <- load.(:mtr_hops, hops) do
      if results != [], do: project.(results, status)
      :ok
    end
  rescue
    e ->
      Logger.error("MTR warehouse store failed: #{inspect(e)}")
      {:error, e}
  end

  defp announce(%{} = broadcast, opts) do
    publish = Keyword.get(opts, :broadcast, &MtrPubSub.broadcast_ingest/1)

    _ =
      publish.(%{
        command_id: Map.get(broadcast, "command_id"),
        target: Map.get(broadcast, "target"),
        agent_id: Map.get(broadcast, "agent_id")
      })

    :ok
  end

  defp announce(_broadcast, _opts), do: :ok

  defp status(%{} = status) do
    %{
      agent_id: Map.get(status, "agent_id"),
      gateway_id: Map.get(status, "gateway_id"),
      partition: Map.get(status, "partition")
    }
  end

  defp status(_status), do: %{agent_id: nil, gateway_id: nil, partition: nil}
end
