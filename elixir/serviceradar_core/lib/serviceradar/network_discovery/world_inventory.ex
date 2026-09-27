defmodule ServiceRadar.NetworkDiscovery.WorldInventory do
  @moduledoc "Bounded inventory projection for persistent topology labels and semantic visibility."

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device

  require Ash.Query

  @batch_size 500
  @infrastructure_types ~w(switch hub firewall loadbalancer accesspoint ap wirelesscontroller wlc hypervisor ids ips)

  @doc "Feeds minimal live inventory to a native world builder in bounded batches."
  def stream(accumulator, callback) when is_function(callback, 2) do
    Device
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(is_nil(deleted_at))
    |> Ash.Query.select([:uid, :type_id, :type, :name, :hostname])
    |> Page.stream!(actor: SystemActor.system(:topology_world), batch_size: @batch_size)
    |> Stream.map(&project/1)
    |> Stream.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, accumulator}, fn rows, {:ok, acc} ->
      case callback.(rows, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "Projects stored device classification; display names never determine importance."
  def project(%{uid: id} = device) do
    %{
      id: id,
      label: label(device, id),
      importance: importance(Map.get(device, :type_id), Map.get(device, :type))
    }
  end

  defp importance(12, _type), do: 0
  defp importance(type_id, _type) when type_id in [9, 10, 11, 13, 14, 15], do: 1

  defp importance(type_id, type) when type_id in [nil, 0, 99] and is_binary(type) do
    case type |> String.downcase() |> String.replace(~r/[\s_-]+/u, "") do
      "router" -> 0
      type when type in @infrastructure_types -> 1
      _type -> 2
    end
  end

  defp importance(_type_id, _type), do: 2

  defp label(device, id) do
    [Map.get(device, :name), Map.get(device, :hostname), id]
    |> Enum.find_value(fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      _value ->
        nil
    end)
    |> bounded_label()
  end

  defp bounded_label(value) when byte_size(value) <= 256, do: value
  defp bounded_label(value), do: value |> binary_part(0, 256) |> complete_utf8()

  defp complete_utf8(value) do
    if String.valid?(value) do
      value
    else
      value |> binary_part(0, byte_size(value) - 1) |> complete_utf8()
    end
  end
end
