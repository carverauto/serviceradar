defmodule ServiceRadar.JSONDocument do
  @moduledoc """
  Bounded JSON documents with an object at the root.

  Rejects duplicate keys before their ordering is discarded. Arrays require explicit opt-in.
  """

  def decode_object(bytes, limit)
      when is_binary(bytes) and is_integer(limit) and limit > 0 and byte_size(bytes) <= limit do
    case Jason.decode(bytes, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = object} -> to_map(object)
      _ -> {:error, :invalid_request}
    end
  end

  def decode_object(_, _), do: {:error, :invalid_request}

  def to_map(%Jason.OrderedObject{} = object, opts \\ []) do
    plain_value(object, Keyword.get(opts, :arrays, false))
  end

  defp plain_value(%Jason.OrderedObject{values: pairs}, arrays?) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, map} ->
      with false <- Map.has_key?(map, key),
           {:ok, value} <- plain_value(value, arrays?) do
        {:cont, {:ok, Map.put(map, key, value)}}
      else
        _ -> {:halt, {:error, :invalid_request}}
      end
    end)
  end

  defp plain_value(value, true) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case plain_value(item, true) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp plain_value(:out_of_range, _arrays?), do: {:error, :invalid_request}
  defp plain_value(value, _arrays?) when is_list(value), do: {:error, :invalid_request}
  defp plain_value(value, _arrays?), do: {:ok, value}
end
