defmodule ServiceRadar.Edge.HelloCapabilities do
  @moduledoc """
  Equal-or-reject comparison of decoded advertisements from the two Hello RPCs.

  Repeated fields are sets and duplicates are refused, including identical duplicates
  on both sides. Nil means no edge support, so two absent carriers agree and an absent
  carrier conflicts with a present one. This is comparison, not admission, raw-byte
  enforcement or authorization; callers still negotiate support and verify grants.
  """
  alias Serviceradar.Edge.V1.EdgeRecordCapabilitiesV1

  @spec compare(term(), term()) :: :ok | {:error, atom()}
  def compare(left, right) do
    with {:ok, a} <- normalize(left),
         {:ok, b} <- normalize(right) do
      if a == b, do: :ok, else: {:error, :capability_conflict}
    end
  end

  defp normalize(nil), do: {:ok, nil}

  defp normalize(%EdgeRecordCapabilitiesV1{} = capabilities) do
    # A codec round trip supplies the generated enum representation and rejects
    # malformed hand-built fields. No byte identity or wire-hygiene claim is made.
    normalized =
      capabilities |> EdgeRecordCapabilitiesV1.encode() |> EdgeRecordCapabilitiesV1.decode()

    EdgeRecordCapabilitiesV1.__message_props__().field_props
    |> Map.values()
    |> Enum.filter(& &1.repeated?)
    |> Enum.reduce_while({:ok, normalized}, fn field, {:ok, acc} ->
      values = Map.fetch!(acc, field.name_atom)
      set = MapSet.new(values)

      if MapSet.size(set) == length(values) do
        {:cont, {:ok, Map.put(acc, field.name_atom, set)}}
      else
        {:halt, {:error, :capability_duplicate}}
      end
    end)
  rescue
    _ -> {:error, :capability_invalid}
  end

  defp normalize(_), do: {:error, :capability_invalid}
end
