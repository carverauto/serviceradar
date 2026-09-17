defmodule ServiceRadar.EventWriter.Processors.FlowAttributionUpdates do
  @moduledoc """
  Applies versioned flow-attribution updates published on
  `events.flow.attribution` to the StarRocks destination.

  Traffic totals are not in the payload. Current-state attribution rows stay in
  CNPG; this processor only shadows historical flow enrichment via a partial
  PRIMARY KEY update so bytes_in/time cannot be NULLed.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Analytics.StarRocks.Attribution
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.Query

  @impl true
  def table_name, do: "ocsf_network_activity"

  @impl true
  def process_batch(messages), do: process_batch(messages, [])

  def process_batch(messages, opts) when is_list(messages) and is_list(opts) do
    parsed =
      messages
      |> Enum.map(&parse_message/1)
      |> Enum.reject(&is_nil/1)

    with {:ok, applicable} <- select_monotonic(parsed, opts),
         {:ok, _} <- persist_updates(applicable, opts) do
      {:ok, length(parsed)}
    end
  end

  defp persist_updates([], _opts), do: {:ok, :empty}

  defp persist_updates(rows, opts) do
    Destination.persist_shadow(
      :flow_attribution,
      rows,
      opts |> Keyword.put(:completed, [:cnpg]) |> Keyword.put(:require_all, true)
    )
  end

  @impl true
  def parse_message(%{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, payload} when is_map(payload) ->
        version = payload["attribution_version"]
        id = payload["id"]

        if is_binary(id) and id != "" and is_integer(version) and version > 0 do
          payload
        end

      _ ->
        nil
    end
  end

  def parse_message(_message), do: nil

  defp select_monotonic(rows, opts) do
    lookup = Keyword.get(opts, :version_lookup, &default_stored_versions/1)

    case lookup.(Enum.map(rows, & &1["id"])) do
      {:error, _} = error -> error
      stored when is_map(stored) -> {:ok, monotonic_rows(rows, stored)}
    end
  end

  defp monotonic_rows(rows, stored) do
    rows
    |> Enum.group_by(& &1["id"])
    |> Enum.flat_map(fn {id, group} ->
      incoming_row = Enum.max_by(group, &attribution_version/1)
      existing = stored_version(stored, id)

      if Attribution.apply_monotonic(existing, attribution_version(incoming_row)) == :apply do
        [incoming_row]
      else
        []
      end
    end)
  end

  defp attribution_version(row) when is_map(row) do
    row["attribution_version"] || Map.get(row, :attribution_version) || 0
  end

  defp stored_version(stored, id) when is_map(stored) do
    Map.get(stored, id) || Map.get(stored, to_string(id)) || 0
  end

  defp default_stored_versions([]), do: %{}

  defp default_stored_versions(ids) do
    quoted =
      ids
      |> Enum.filter(&(&1 =~ ~r/^[A-Za-z0-9:_-]+$/))
      |> Enum.map_join(",", &"'#{&1}'")

    if quoted == "" do
      %{}
    else
      sql =
        "SELECT id, attribution_version FROM serviceradar.ocsf_network_activity WHERE id IN (#{quoted})"

      case Query.execute(sql) do
        {:ok, %{columns: columns, rows: rows}} ->
          id_idx = Enum.find_index(columns, &(&1 == "id")) || 0
          ver_idx = Enum.find_index(columns, &(&1 == "attribution_version")) || 1

          Map.new(rows, fn row ->
            {Enum.at(row, id_idx), to_int(Enum.at(row, ver_idx))}
          end)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_binary(value), do: String.to_integer(value)
  defp to_int(_), do: 0
end
