defmodule ServiceRadarWebNGWeb.GatewayHelpers do
  @moduledoc false

  def extract_gateway_id(%{gateway_id: id}) when is_binary(id) and id != "", do: id

  def extract_gateway_id(%{key: {_partition, node}}) when is_atom(node),
    do: to_string(node)

  def extract_gateway_id(%{key: key}) when is_binary(key), do: key
  def extract_gateway_id(%{key: key}) when is_atom(key), do: to_string(key)
  def extract_gateway_id(%{id: id}) when is_binary(id), do: id
  def extract_gateway_id(_), do: ""

  def gateway_option(gateway) do
    id = extract_gateway_id(gateway)

    label =
      case gateway do
        %{partition_id: partition} when is_binary(partition) and partition != "" ->
          "#{id} (#{partition})"

        %{partition_id: partition} when is_atom(partition) ->
          "#{id} (#{partition})"

        %{partition: partition} when is_binary(partition) and partition != "" ->
          "#{id} (#{partition})"

        %{partition: partition} when is_atom(partition) ->
          "#{id} (#{partition})"

        _ ->
          id
      end

    {label, id}
  end

  def gateway_options(gateways) when is_list(gateways) do
    gateways
    |> Enum.map(&gateway_option/1)
    |> Enum.filter(&valid_gateway_option?/1)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp valid_gateway_option?({_label, id}) when is_binary(id), do: id != ""
  defp valid_gateway_option?({_label, _id}), do: false
end
