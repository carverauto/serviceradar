defmodule ServiceRadar.Automation.Northbound.TargetPayloadContract do
  @moduledoc """
  Applies descriptor-declared target payload field contracts.

  Stored invocation snapshots remain full audit snapshots. The contract only
  narrows the payload sent to a plugin when a descriptor explicitly declares
  supported target fields in metadata.
  """

  @always_include ~w(kind device_uid interface_uid event_id northbound_job_id callback)
  @metadata_keys ~w(target_fields supported_target_fields action_target_fields)

  @spec apply(map() | nil, [map()]) :: [map()]
  def apply(descriptor, targets) when is_list(targets) do
    case field_contract(descriptor) do
      nil -> targets
      contract -> Enum.map(targets, &apply_target_contract(&1, contract))
    end
  end

  def apply(_descriptor, targets), do: targets

  defp apply_target_contract(%{} = target, contract) do
    kind = target |> Map.get("kind") |> to_string()

    case fields_for_kind(contract, kind) do
      [] ->
        target

      fields ->
        allowed = MapSet.new(@always_include ++ fields)

        Map.filter(target, fn {key, _value} ->
          MapSet.member?(allowed, to_string(key))
        end)
    end
  end

  defp apply_target_contract(target, _contract), do: target

  defp field_contract(%{metadata: metadata}), do: metadata_field_contract(metadata)
  defp field_contract(%{"metadata" => metadata}), do: metadata_field_contract(metadata)
  defp field_contract(_descriptor), do: nil

  defp metadata_field_contract(%{} = metadata) do
    Enum.find_value(@metadata_keys, fn key ->
      normalize_contract(Map.get(metadata, key) || Map.get(metadata, atom_key(key)))
    end)
  end

  defp metadata_field_contract(_metadata), do: nil

  defp normalize_contract(fields) when is_list(fields) do
    fields
    |> normalize_field_list()
    |> case do
      [] -> nil
      normalized -> %{"default" => normalized}
    end
  end

  defp normalize_contract(%{} = contract) do
    contract
    |> Enum.reduce(%{}, fn {kind, fields}, acc ->
      case normalize_field_list(fields) do
        [] -> acc
        normalized -> Map.put(acc, to_string(kind), normalized)
      end
    end)
    |> case do
      empty when map_size(empty) == 0 -> nil
      normalized -> normalized
    end
  end

  defp normalize_contract(_value), do: nil

  defp normalize_field_list(fields) when is_list(fields) do
    fields
    |> Enum.map(&normalize_field_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_field_list(_fields), do: []

  defp normalize_field_name(field) when is_atom(field), do: Atom.to_string(field)

  defp normalize_field_name(field) when is_binary(field) do
    field = String.trim(field)
    if field == "", do: nil, else: field
  end

  defp normalize_field_name(_field), do: nil

  defp fields_for_kind(contract, kind) do
    Map.get(contract, kind) || Map.get(contract, "default") || []
  end

  defp atom_key("target_fields"), do: :target_fields
  defp atom_key("supported_target_fields"), do: :supported_target_fields
  defp atom_key("action_target_fields"), do: :action_target_fields
end
