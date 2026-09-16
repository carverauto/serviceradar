defmodule ServiceRadarWebNG.SRQL.Batch do
  @moduledoc false

  alias ServiceRadarWebNG.SRQL.EntityAccess

  def run(queries, scope, translate, execute, execute_shared) do
    with :ok <- validate(queries),
         :ok <- authorize_all(queries, scope),
         {:ok, %{"lanes" => lanes, "translation" => shared}}
         when is_list(lanes) and (is_map(shared) or is_nil(shared)) <- translate.(requests(queries)),
         true <- length(lanes) == length(queries) do
      lanes = Enum.zip_with(queries, lanes, fn {key, query}, lane -> {key, Map.put(lane, "_query", query)} end)

      if is_map(shared) do
        execute_shared.(shared, lanes)
      else
        {:ok, execute_separately(lanes, execute)}
      end
    else
      false -> {:error, :invalid_srql_batch_translation}
      {:error, _} = error -> error
      _ -> {:error, :invalid_srql_batch_translation}
    end
  end

  defp validate(queries) when is_list(queries) and length(queries) in 2..4 do
    valid = Enum.all?(queries, &match?({key, query} when (is_atom(key) or is_binary(key)) and is_binary(query), &1))

    if valid and length(Enum.uniq_by(queries, &elem(&1, 0))) == length(queries),
      do: :ok,
      else: {:error, :invalid_srql_batch}
  end

  defp validate(_queries), do: {:error, :invalid_srql_batch}

  defp authorize_all(queries, scope) do
    Enum.reduce_while(queries, :ok, fn {_key, query}, :ok ->
      case EntityAccess.authorize(query, scope) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp requests(queries), do: Enum.map(queries, fn {_key, query} -> %{"query" => query} end)

  # Preserve the successful earlier lanes, and avoid another expensive scan after failure.
  @doc false
  def execute_separately(lanes, execute) do
    {results, _error} =
      Enum.reduce(lanes, {%{}, nil}, fn {key, lane}, {results, error} ->
        result = error || execute.(lane)
        next_error = if match?({:error, _}, result), do: result
        {Map.put(results, key, result), next_error}
      end)

    results
  end

  def split(%Postgrex.Result{columns: ["timestamp", "series", "value", "batch_index"], rows: rows}, lanes, respond) do
    if Enum.all?(rows, &valid_row?(&1, length(lanes))) do
      grouped = Enum.group_by(rows, &List.last/1, &Enum.take(&1, 3))

      results =
        lanes
        |> Enum.with_index()
        |> Map.new(fn {{key, lane}, index} ->
          result = %Postgrex.Result{columns: ["timestamp", "series", "value"], rows: Map.get(grouped, index, [])}
          {key, {:ok, respond.(lane, result)}}
        end)

      {:ok, results}
    else
      {:error, :invalid_srql_batch_result}
    end
  end

  def split(_result, _lanes, _respond), do: {:error, :invalid_srql_batch_result}

  defp valid_row?([_timestamp, _series, _value, index], lane_count),
    do: is_integer(index) and index >= 0 and index < lane_count

  defp valid_row?(_row, _lane_count), do: false
end
