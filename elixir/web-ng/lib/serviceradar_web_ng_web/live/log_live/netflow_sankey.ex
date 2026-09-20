defmodule ServiceRadarWebNGWeb.LogLive.NetflowSankey do
  @moduledoc """
  The NetFlow Sankey's edges: the heaviest `source subnet -> port -> destination
  subnet` paths in the window.

  The subnet grouping is done by the warehouse, so "top edges" is ranked over
  every flow in the window. It used to be done here, over the 200 heaviest
  address triples the page had fetched, and then cut again to the top 8 ports.
  On a window where two busy subnets held all 200 rows that left two subnets
  and eight ports, so a panel titled "top 40 edges" could not show more than a
  handful, and no lighter subnet ever reached it.
  """

  @max_edges 40

  @type edge :: %{
          src: String.t(),
          mid: String.t(),
          port: non_neg_integer(),
          dst: String.t(),
          bytes: non_neg_integer()
        }

  @spec max_edges() :: pos_integer()
  def max_edges, do: @max_edges

  @doc "The grouped SRQL query for a base `in:flows ...` query and a /16 or /24 prefix."
  @spec query(String.t(), 16 | 24) :: String.t()
  def query(base_query, prefix) when is_binary(base_query) and prefix in [16, 24] do
    ~s|#{base_query} stats:"sum(bytes_total) as total_bytes by src_cidr:#{prefix}, dst_endpoint_port, | <>
      ~s|dst_cidr:#{prefix}" sort:total_bytes:desc limit:#{@max_edges}|
  end

  @doc """
  Turns the grouped rows into edges, heaviest first.

  `port_label` names the middle node for a port, for example `"HTTPS:443"`.
  Rows without both subnets, or without traffic, draw nothing and are dropped.
  """
  @spec edges([map()], 16 | 24, (non_neg_integer() -> String.t())) :: [edge()]
  def edges(rows, prefix, port_label) when is_list(rows) and prefix in [16, 24] and is_function(port_label, 1) do
    rows
    |> Enum.map(fn row ->
      port = to_int(Map.get(row, "dst_endpoint_port"))

      %{
        src: subnet(Map.get(row, "src_cidr_#{prefix}"), prefix),
        mid: port_label.(port),
        port: port,
        dst: subnet(Map.get(row, "dst_cidr_#{prefix}"), prefix),
        bytes: to_int(Map.get(row, "total_bytes"))
      }
    end)
    |> Enum.reject(&(is_nil(&1.src) or is_nil(&1.dst) or &1.bytes <= 0))
    |> Enum.sort_by(& &1.bytes, :desc)
    |> Enum.take(@max_edges)
  end

  @doc "Total bytes per distinct value of `key` across `edges`, heaviest first."
  @spec totals_by([edge()], :src | :mid | :dst) :: [{String.t(), non_neg_integer()}]
  def totals_by(edges, key) when is_list(edges) and key in [:src, :mid, :dst] do
    edges
    |> Enum.reduce(%{}, fn edge, acc -> Map.update(acc, Map.fetch!(edge, key), edge.bytes, &(&1 + edge.bytes)) end)
    |> Enum.sort_by(fn {_value, bytes} -> -bytes end)
  end

  # The warehouse returns the network address without its length.
  defp subnet(value, prefix) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      "Unknown" -> nil
      network -> if String.contains?(network, "/"), do: network, else: "#{network}/#{prefix}"
    end
  end

  defp subnet(_value, _prefix), do: nil

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> trunc(number)
      :error -> 0
    end
  end

  defp to_int(_value), do: 0
end
