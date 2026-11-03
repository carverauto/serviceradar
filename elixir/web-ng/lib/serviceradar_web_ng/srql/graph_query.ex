defmodule ServiceRadarWebNG.SRQL.GraphQuery do
  @moduledoc """
  Executes the SRQL entities that read the Dgraph topology graph rather than SQL:
  `in:device_graph` (one device's neighbourhood) and `in:graph` (read-only DQL).

  Filters come from the SRQL parser's AST and are validated with the same rules
  as `rust/srql/src/query/device_graph.rs` and `graph_dql.rs`.
  """

  alias ServiceRadar.Dgraph
  alias ServiceRadarSRQL.Native

  @entities ~w(device_graph devicegraph graph graph_dql)

  @doc "Whether `entity` (as `EntityAccess.extract_entity/1` returns it) reads Dgraph."
  @spec entity?(String.t() | nil) :: boolean()
  def entity?(entity), do: entity in @entities

  @spec execute(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def execute(query) when is_binary(query) do
    with {:ok, ast_json} <- Native.parse_ast(query),
         {:ok, ast} <- Jason.decode(ast_json) do
      run(ast)
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(%{"entity" => "device_graph", "filters" => filters}) do
    with {:ok, device_id, include_topology} <- device_graph_params(filters),
         {:ok, neighborhood} <- Dgraph.query_device_neighborhood(device_id, include_topology) do
      {:ok, List.wrap(neighborhood)}
    end
  end

  defp run(%{"entity" => "graph_dql", "filters" => filters}) do
    with {:ok, dql} <- dql_param(filters) do
      Dgraph.query_graph_rows(dql)
    end
  end

  defp run(_ast), do: {:error, "entity is not a Dgraph topology read"}

  defp device_graph_params(filters) do
    filters
    |> Enum.reduce_while({:ok, nil, true}, fn filter, {:ok, device_id, include_topology} ->
      case device_graph_filter(filter) do
        {:device_id, id} -> {:cont, {:ok, id, include_topology}}
        {:include_topology, value} -> {:cont, {:ok, device_id, value}}
        :ignore -> {:cont, {:ok, device_id, include_topology}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, nil, _} -> {:error, "device_id filter is required for device_graph queries"}
      other -> other
    end
  end

  defp device_graph_filter(%{"field" => "device_id"} = filter) do
    with {:ok, value} <- eq_scalar(filter, "device_id") do
      case String.trim(value) do
        "" -> {:error, "device_id filter cannot be empty"}
        id -> with :ok <- validate_device_id(id), do: {:device_id, id}
      end
    end
  end

  defp device_graph_filter(%{"field" => field} = filter) when field in ["collector_owned", "collector_owned_only"] do
    with {:ok, value} <- eq_scalar(filter, "collector_owned"),
         {:ok, collector_owned?} <- parse_bool(value, false, "collector_owned") do
      if collector_owned? do
        {:error, "collector_owned:true is not supported: collector ownership is not part of the topology graph"}
      else
        :ignore
      end
    end
  end

  defp device_graph_filter(%{"field" => "include_topology"} = filter) do
    with {:ok, value} <- eq_scalar(filter, "include_topology"),
         {:ok, include_topology} <- parse_bool(value, true, "include_topology") do
      {:include_topology, include_topology}
    end
  end

  defp device_graph_filter(%{"field" => field}), do: {:error, "unsupported filter field '#{field}' for device_graph"}

  defp dql_param(filters) do
    case Enum.find(filters, &(&1["field"] in ["dql", "query"])) do
      nil ->
        {:error, ~s|graph_dql requires dql:"..."|}

      filter ->
        with {:ok, value} <- eq_scalar(filter, "dql") do
          case String.trim(value) do
            "" -> {:error, "dql query cannot be empty"}
            dql -> {:ok, dql}
          end
        end
    end
  end

  defp eq_scalar(%{"op" => "eq", "value" => value}, _name) when is_binary(value), do: {:ok, value}
  defp eq_scalar(%{"op" => "eq"}, _name), do: {:error, "expected scalar value"}
  defp eq_scalar(_filter, name), do: {:error, "#{name} filter only supports equality"}

  defp parse_bool(value, default, name) do
    case value |> String.trim() |> String.downcase() do
      "" -> {:ok, default}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, "#{name} filter expects boolean true/false"}
    end
  end

  # The id becomes a DQL string literal, which cannot carry a quote or a
  # backslash; control characters are never part of a device id.
  defp validate_device_id(id) do
    cond do
      String.contains?(id, ["\"", "\\"]) -> {:error, "device_id cannot contain quotes or backslashes"}
      String.match?(id, ~r/[\x00-\x1f\x7f]/) -> {:error, "device_id contains invalid control characters"}
      true -> :ok
    end
  end
end
