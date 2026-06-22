defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Utils.Cypher do
  @moduledoc false

  alias ServiceRadar.Graph

  def set_prop(_node, _field, nil), do: ""
  def set_prop(_node, _field, ""), do: ""

  def set_prop(node, field, value) when is_list(value) do
    list = Enum.map_join(value, ", ", &cypher_value/1)
    "SET #{node}.#{field} = [#{list}]"
  end

  def set_prop(node, field, value) do
    "SET #{node}.#{field} = #{cypher_value(value)}"
  end

  def cypher_value(nil), do: "null"
  def cypher_value(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  def cypher_value(value) when is_integer(value), do: Integer.to_string(value)

  def cypher_value(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 8])

  def cypher_value(value) when is_binary(value), do: "'#{Graph.escape(value)}'"
  def cypher_value(value) when is_atom(value), do: "'#{Graph.escape(value)}'"
  def cypher_value(value), do: "'#{Graph.escape(to_string(value))}'"
end
