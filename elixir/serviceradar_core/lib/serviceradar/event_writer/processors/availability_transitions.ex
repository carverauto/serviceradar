defmodule ServiceRadar.EventWriter.Processors.AvailabilityTransitions do
  @moduledoc """
  Stores the merged device availability history published on
  `availability.transitions.device` (`ServiceRadar.Inventory.Availability.History`).

  StarRocks is the only store when it is enabled (dataset
  `:device_availability_transitions`); otherwise the rows go to the CNPG hypertable
  `platform.device_availability_transitions`. Never both. Both stores key a record by
  `(device_uid, changed_at, to_state)`, so a redelivered or republished record is stored
  once. A failed write fails the batch so JetStream redelivers it; a message that does not
  decode as a history record is dropped and counted, since a retry would fail the same way.
  Once a batch is stored, its devices are announced through `DevicePubSub` so a reader
  rebuilds their timelines from the stored rows.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.Inventory.DevicePubSub

  require Logger

  @states ~w(available unavailable unknown)

  @impl true
  def table_name, do: "device_availability_transitions"

  @impl true
  def process_batch(messages), do: process_batch(messages, [])

  @doc false
  # `:starrocks_enabled` and `:load` replace `Destination.enabled?/0` and
  # `Destination.persist_warehouse/2`.
  def process_batch(messages, opts) when is_list(messages) and is_list(opts) do
    {rows, rejected} = decode(messages)

    if rejected > 0 do
      Logger.warning("AvailabilityTransitions dropped undecodable messages", count: rejected)
    end

    result =
      cond do
        rows == [] -> {:ok, 0}
        Keyword.get_lazy(opts, :starrocks_enabled, &Destination.enabled?/0) -> load(rows, opts)
        true -> insert(rows)
      end

    with {:ok, _count} <- result do
      rows |> Enum.map(& &1.device_uid) |> Enum.uniq() |> DevicePubSub.broadcast_invalidated()
      result
    end
  end

  @impl true
  def parse_message(%{data: data}) when is_binary(data) do
    with {:ok, %{} = record} <- Jason.decode(data),
         {:ok, row} <- row(record) do
      row
    else
      _ -> nil
    end
  end

  def parse_message(_message), do: nil

  defp decode(messages) do
    {rows, rejected} =
      Enum.reduce(messages, {[], 0}, fn message, {rows, rejected} ->
        case parse_message(message) do
          nil -> {rows, rejected + 1}
          row -> {[row | rows], rejected}
        end
      end)

    {Enum.reverse(rows), rejected}
  end

  defp row(record) do
    with uid when is_binary(uid) and uid != "" <- record["device_uid"],
         from when from in @states <- record["from_state"],
         to when to in @states <- record["to_state"],
         {:ok, changed_at} <- timestamp(record["changed_at"]),
         {:ok, from_since} <- optional_timestamp(record["from_since"]) do
      {:ok,
       %{
         device_uid: uid,
         from_state: from,
         from_since: from_since,
         to_state: to,
         changed_at: changed_at,
         authority_class: text(record["authority_class"]),
         source_kind: text(record["source_kind"]),
         reporter_agent_id: text(record["reporter_agent_id"]),
         rule: text(record["rule"]),
         conflict: record["conflict"] == true,
         created_at: DateTime.utc_now()
       }}
    else
      _ -> :error
    end
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _ -> :error
    end
  end

  defp timestamp(_value), do: :error

  defp optional_timestamp(nil), do: {:ok, nil}
  defp optional_timestamp(value), do: timestamp(value)

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  defp load(rows, opts) do
    load = Keyword.get(opts, :load, &Destination.persist_warehouse/2)

    case load.(:device_availability_transitions, rows) do
      {:ok, _result} -> {:ok, length(rows)}
      {:error, _reason} = error -> error
    end
  end

  defp insert(rows) do
    {count, _} =
      BulkInsert.insert_all(table_name(), rows,
        on_conflict: :nothing,
        conflict_target: [:device_uid, :changed_at, :to_state],
        returning: false
      )

    {:ok, count}
  end
end
