defmodule ServiceRadar.Observability.MtrResultPublisher do
  @moduledoc """
  Publishes MTR trace results to JetStream for EventWriter to persist.

  Scheduled checks, on-demand runs and bulk jobs all deliver full MTR traces to
  core. Core does not write them: it publishes one message per trace to
  `mtr.results.ingest`, and `ServiceRadar.EventWriter.Processors.Mtr` persists
  it. That keeps MTR on the JetStream-first path every other telemetry dataset
  uses, and gives EventWriter single ownership of MTR storage.

  Each message carries a `trace_uuid` generated here. The processor stores the
  trace under that id and skips ids it has already stored, so a redelivered
  message does not create a second copy. A result with no usable timestamp is
  stamped at publish time, so every delivery stores the trace at the same time
  and the processor's id-plus-time lookup finds the copy it stored earlier.

  ## Message format (JSON)

      {
        "payload": {"results": [<one ingestor result>]},
        "status": {"agent_id": "...", "gateway_id": "...", "partition": "..."},
        "broadcast": {"command_id": "...", "target": "...", "agent_id": "..."}
      }

  `broadcast` is optional; when present the processor announces the stored
  trace on `ServiceRadar.Observability.MtrPubSub` so open pages refresh.
  """

  alias ServiceRadar.NATS.JetStreamPublish
  alias ServiceRadar.Observability.MtrMetricsIngestor

  require Logger

  @subject "mtr.results.ingest"

  @doc "Subject the MTR results stream captures."
  @spec subject() :: String.t()
  def subject, do: @subject

  @doc """
  Publishes every result in `payload` (an ingestor payload: `%{"results" => [...]}`
  or a single result map) with the ingest `status`.

  Options:

    * `:broadcast` - a map, or a function of the result returning one, attached
      so the processor can announce the stored trace
    * `:publish` - `(subject, body, opts -> :ok | {:error, term})` (tests)

  Returns `:ok` once every message is stored, or the first error.
  """
  @spec publish(map(), map(), keyword()) :: :ok | {:error, term()}
  def publish(payload, status, opts \\ []) when is_map(payload) do
    publish_fun = Keyword.get(opts, :publish, &JetStreamPublish.publish/3)

    payload
    |> results()
    |> Enum.reduce_while(:ok, fn result, :ok ->
      trace_uuid = Ecto.UUID.generate()
      result = result |> Map.put("trace_uuid", trace_uuid) |> stamp_time()
      envelope = envelope(result, status, opts)

      with {:ok, body} <- Jason.encode(envelope),
           :ok <- publish_fun.(@subject, body, msg_id: trace_uuid) do
        {:cont, :ok}
      else
        {:error, reason} ->
          Logger.warning("MTR result publish failed", reason: inspect(reason))
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  def results(%{"results" => results}) when is_list(results), do: Enum.filter(results, &is_map/1)
  def results(%{results: results}) when is_list(results), do: Enum.filter(results, &is_map/1)
  def results(%{"result" => result}) when is_map(result), do: [result]
  def results(result) when is_map(result), do: [result]

  defp stamp_time(result) do
    case MtrMetricsIngestor.trace_time(result) do
      nil -> Map.put(result, "timestamp", System.os_time(:second))
      _time -> result
    end
  end

  defp envelope(result, status, opts) do
    base = %{
      "payload" => %{"results" => [result]},
      "status" => %{
        "agent_id" => field(status, :agent_id),
        "gateway_id" => field(status, :gateway_id),
        "partition" => field(status, :partition)
      }
    }

    case broadcast(result, Keyword.get(opts, :broadcast)) do
      nil -> base
      broadcast -> Map.put(base, "broadcast", stringify(broadcast))
    end
  end

  defp broadcast(result, fun) when is_function(fun, 1), do: fun.(result)
  defp broadcast(_result, %{} = broadcast), do: broadcast
  defp broadcast(_result, _none), do: nil

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field(_map, _key), do: nil
end
