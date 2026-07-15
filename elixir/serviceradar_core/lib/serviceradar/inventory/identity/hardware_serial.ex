defmodule ServiceRadar.Inventory.Identity.HardwareSerial do
  @moduledoc """
  Manufacturer-scoped hardware serial identity normalization.

  A serial becomes strong evidence only when both its vendor namespace and
  serial value pass conservative allowlists. Display metadata is unaffected
  when a value is rejected.
  """

  alias ServiceRadar.Inventory.Sync.FieldAliases

  @serial_keys [
    "serial_number",
    :serial_number,
    "serial",
    :serial,
    "serialNumber",
    :serialNumber,
    "chassis_serial",
    :chassis_serial,
    "chassisSerial",
    :chassisSerial
  ]

  @vendor_namespaces %{
    "arista" => "arista",
    "aristanetworks" => "arista",
    "aruba" => "hpe",
    "arubanetworks" => "hpe",
    "axis" => "axis",
    "axiscommunications" => "axis",
    "checkpoint" => "checkpoint",
    "checkpointsoftware" => "checkpoint",
    "cisco" => "cisco",
    "ciscosystems" => "cisco",
    "ciscosystemsinc" => "cisco",
    "dell" => "dell",
    "dellemc" => "dell",
    "fortinet" => "fortinet",
    "hewlettpackard" => "hpe",
    "hewlettpackardenterprise" => "hpe",
    "hp" => "hpe",
    "hpe" => "hpe",
    "hpearuba" => "hpe",
    "hpearubanetworks" => "hpe",
    "juniper" => "juniper",
    "junipernetworks" => "juniper",
    "mikrotik" => "mikrotik",
    "netgear" => "netgear",
    "paloalto" => "paloalto",
    "paloaltonetworks" => "paloalto",
    "ubiquiti" => "ubiquiti",
    "ubiquitinetworks" => "ubiquiti",
    "ubnt" => "ubiquiti",
    "vmware" => "vmware"
  }

  @placeholder_serials MapSet.new(~w(
    0000 00000000 0123456789 123456789
    CHASSISSERIALNUMBER DEFAULT NONE NOTAPPLICABLE NOTAVAILABLE NULL
    SERIALNUMBER SYSTEMSERIALNUMBER TOBEFILLEDBYOEM UNKNOWN UNSPECIFIED
  ))

  @spec from_update(map()) :: String.t() | nil
  def from_update(update) when is_map(update) do
    case evidence(update) do
      {:ok, %{identifier_value: value}} -> value
      :error -> nil
    end
  end

  def from_update(_update), do: nil

  @spec evidence(map()) :: {:ok, map()} | :error
  def evidence(update) when is_map(update) do
    metadata = map_value(update, :metadata)
    hw_info = map_value(update, :hw_info)
    vendor = first_string(metadata, FieldAliases.vendor_aliases())
    serial = first_string(metadata, @serial_keys) || first_string(hw_info, @serial_keys)

    with {:ok, vendor_namespace} <- canonical_vendor(vendor),
         {:ok, normalized_serial} <- normalize_serial(serial) do
      {:ok,
       %{
         identifier_value: "#{vendor_namespace}:#{normalized_serial}",
         vendor_namespace: vendor_namespace,
         normalized_serial: normalized_serial
       }}
    else
      _ -> :error
    end
  end

  def evidence(_update), do: :error

  @spec canonical_vendor(term()) :: {:ok, String.t()} | :error
  def canonical_vendor(vendor) when is_binary(vendor) do
    key =
      vendor
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/u, "")

    case Map.get(@vendor_namespaces, key) do
      nil -> :error
      namespace -> {:ok, namespace}
    end
  end

  def canonical_vendor(_vendor), do: :error

  @spec normalize_serial(term()) :: {:ok, String.t()} | :error
  def normalize_serial(serial) when is_binary(serial) do
    trimmed = String.trim(serial)

    cond do
      trimmed == "" ->
        :error

      byte_size(trimmed) > 128 ->
        :error

      String.match?(trimmed, ~r/[\s,;|\/]/u) ->
        :error

      true ->
        normalized =
          trimmed
          |> String.upcase()
          |> String.replace(~r/[^A-Z0-9]/u, "")

        validate_normalized_serial(normalized)
    end
  end

  def normalize_serial(_serial), do: :error

  defp validate_normalized_serial(normalized) do
    cond do
      byte_size(normalized) < 4 or byte_size(normalized) > 64 -> :error
      MapSet.member?(@placeholder_serials, normalized) -> :error
      String.match?(normalized, ~r/^0+$/) -> :error
      one_repeated_character?(normalized) -> :error
      true -> {:ok, normalized}
    end
  end

  defp one_repeated_character?(<<first, rest::binary>>) do
    rest != "" and Enum.all?(:binary.bin_to_list(rest), &(&1 == first))
  end

  defp one_repeated_character?(_value), do: false

  defp map_value(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp first_string(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) -> value |> String.trim() |> blank_to_nil()
        _ -> nil
      end
    end)
  end

  defp first_string(_map, _keys), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
