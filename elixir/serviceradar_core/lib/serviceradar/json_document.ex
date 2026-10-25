defmodule ServiceRadar.JSONDocument do
  @moduledoc """
  Bounded object-only JSON for private installation and control documents.

  Rejects duplicate keys before their ordering is discarded. Arrays are outside
  these contracts; each field must retain one unambiguous interpretation.
  """

  def decode_object(bytes, limit)
      when is_binary(bytes) and is_integer(limit) and limit > 0 and byte_size(bytes) <= limit do
    case Jason.decode(bytes, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = decoded} -> plain_value(decoded)
      _ -> {:error, :invalid_request}
    end
  end

  def decode_object(_, _), do: {:error, :invalid_request}

  defp plain_value(%Jason.OrderedObject{values: pairs}) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, map} ->
      with false <- Map.has_key?(map, key),
           {:ok, value} <- plain_value(value) do
        {:cont, {:ok, Map.put(map, key, value)}}
      else
        _ -> {:halt, {:error, :invalid_request}}
      end
    end)
  end

  defp plain_value(value) when is_list(value), do: {:error, :invalid_request}
  defp plain_value(value), do: {:ok, value}
end
