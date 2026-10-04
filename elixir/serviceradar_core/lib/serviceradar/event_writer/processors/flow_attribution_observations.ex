defmodule ServiceRadar.EventWriter.Processors.FlowAttributionObservations do
  @moduledoc """
  Loads netprobe process attribution observations published on
  `flows.attribution.observations` into the StarRocks table
  `flow_process_attribution_observations`.

  The table is append-only and warehouse-only: there is no CNPG copy. A failed
  load fails the batch so JetStream redelivers it. Core publishes observations
  only while StarRocks is enabled; a message that arrives after the warehouse was
  turned off has nowhere to go and is acknowledged without being stored.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.FlowAttribution.Observations

  require Logger

  @impl true
  def table_name, do: "flow_process_attribution_observations"

  @impl true
  def process_batch(messages), do: process_batch(messages, [])

  @doc false
  # `:starrocks_enabled` and `:load` replace `Destination.enabled?/0` and
  # `Destination.persist_warehouse/2`.
  def process_batch(messages, opts) when is_list(messages) and is_list(opts) do
    {rows, rejected} = decode(messages)

    if rejected > 0 do
      Logger.warning("FlowAttributionObservations dropped undecodable messages",
        count: rejected
      )
    end

    cond do
      rows == [] ->
        {:ok, 0}

      not Keyword.get_lazy(opts, :starrocks_enabled, &Destination.enabled?/0) ->
        {:ok, 0}

      true ->
        load = Keyword.get(opts, :load, &Destination.persist_warehouse/2)

        case load.(:flow_attribution_observations, rows) do
          {:ok, _result} -> {:ok, length(rows)}
          {:error, _reason} = error -> error
        end
    end
  end

  defp decode(messages) do
    Enum.reduce(messages, {[], 0}, fn message, {rows, rejected} ->
      case Observations.decode(message_data(message)) do
        {:ok, decoded} -> {decoded ++ rows, rejected}
        :error -> {rows, rejected + 1}
      end
    end)
  end

  defp message_data(%{data: data}), do: data
  defp message_data(_message), do: nil
end
