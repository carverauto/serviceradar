defmodule ServiceRadar.EventWriter.Processors.Mtr do
  @moduledoc """
  Persists MTR trace results from the `mtr.results.>` stream.

  `ServiceRadar.Observability.MtrResultPublisher` publishes one message per
  trace for scheduled checks, on-demand runs and bulk jobs. This processor is
  the only writer of those traces: it stores each one through
  `ServiceRadar.Observability.MtrMetricsIngestor`, then announces it on
  `ServiceRadar.Observability.MtrPubSub` when the message asks for that, so a
  page waiting on the trace refreshes after it is stored rather than before.

  Every message carries a `trace_uuid`. Traces already stored under their id
  are skipped, so a batch that failed part way and is redelivered does not
  duplicate the traces that did land.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Observability.MtrMetricsIngestor
  alias ServiceRadar.Observability.MtrPubSub

  require Logger

  @impl true
  def table_name, do: "mtr_traces"

  @impl true
  def process_batch(messages) do
    envelopes =
      messages
      |> Enum.map(&parse_message/1)
      |> Enum.reject(&is_nil/1)

    Enum.reduce_while(envelopes, {:ok, 0}, fn envelope, {:ok, count} ->
      case persist(envelope) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

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
  def persist(%{payload: payload, status: status, broadcast: broadcast}, opts \\ []) do
    ingest = Keyword.get(opts, :ingest, &MtrMetricsIngestor.ingest/3)

    case ingest.(payload, status, skip_existing: true) do
      :ok ->
        announce(broadcast, opts)
        :ok

      {:error, reason} = error ->
        Logger.warning("MTR result persist failed", reason: inspect(reason))
        error
    end
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
