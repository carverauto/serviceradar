defmodule ServiceRadar.Inventory.ActiveFingerprintPayload do
  @moduledoc false

  @base "active_fingerprint"
  @fingerprint_source "serviceradar-sweep-active"
  @recog_protocols [
    {"http", :http},
    {"ssh", :ssh},
    {"smb", :smb},
    {"ftp", :ftp},
    {"telnet", :telnet},
    {"smtp", :smtp},
    {"ntp", :ntp},
    {"rdp", :rdp},
    {"dns", :dns}
  ]

  @spec enrich_metadata(map()) :: map()
  def enrich_metadata(metadata) when is_map(metadata) do
    nested = get_map(metadata, [@base, :active_fingerprint])

    enriched =
      nested
      |> put_nested("os", os_payload(metadata, nested))
      |> put_nested("recog", recog_payload(metadata, nested))

    if map_size(enriched) == 0 do
      metadata
    else
      Map.put(metadata, @base, enriched)
    end
  end

  def enrich_metadata(_metadata), do: %{}

  @spec enrich_os(map(), map()) :: map()
  def enrich_os(os, metadata) when is_map(os) and is_map(metadata) do
    case os_payload(metadata, get_map(metadata, [@base, :active_fingerprint])) do
      payload when map_size(payload) > 0 -> Map.put(os, @base, payload)
      _ -> os
    end
  end

  def enrich_os(_os, metadata) when is_map(metadata), do: enrich_os(%{}, metadata)
  def enrich_os(os, _metadata) when is_map(os), do: os
  def enrich_os(_os, _metadata), do: %{}

  defp os_payload(metadata, nested) do
    os = get_map(nested, ["os", :os])

    payload =
      %{}
      |> maybe_put("family", active_string(metadata, os, "os.family", ["family"]))
      |> maybe_put("name", active_string(metadata, os, "os.name", ["name"]))
      |> maybe_put(
        "version_range",
        active_string(metadata, os, "os.version_range", ["version_range"])
      )
      |> maybe_put("confidence", active_number(metadata, os, "os.confidence", ["confidence"]))

    if map_size(payload) == 0 do
      %{}
    else
      payload
      |> maybe_put("source", @fingerprint_source)
      |> maybe_put("observed_at", observed_at(metadata, os))
    end
  end

  defp recog_payload(metadata, nested) do
    existing = get_map(nested, ["recog", :recog])

    Enum.reduce(@recog_protocols, existing, fn {protocol, protocol_atom}, acc ->
      payload =
        recog_protocol_payload(
          metadata,
          get_map(existing, [protocol, protocol_atom]),
          protocol
        )

      put_nested(acc, protocol, payload)
    end)
  end

  defp recog_protocol_payload(metadata, nested, protocol) do
    %{}
    |> maybe_put(
      "product",
      active_string(metadata, nested, "recog.#{protocol}.product", ["product"])
    )
    |> maybe_put(
      "version",
      active_string(metadata, nested, "recog.#{protocol}.version", ["version"])
    )
    |> maybe_put(
      "os_family",
      active_string(metadata, nested, "recog.#{protocol}.os_family", ["os_family"])
    )
  end

  defp put_nested(map, _key, payload) when payload == %{}, do: map
  defp put_nested(map, key, payload), do: Map.put(map, key, payload)

  defp active_string(metadata, nested_payload, suffix, nested_keys) do
    get_string(metadata, ["#{@base}.#{suffix}"]) || get_string(nested_payload, nested_keys)
  end

  defp active_number(metadata, nested_payload, suffix, nested_keys) do
    metadata
    |> get_value(["#{@base}.#{suffix}"])
    |> parse_number()
    |> case do
      nil ->
        nested_payload
        |> get_value(nested_keys)
        |> parse_number()

      value ->
        value
    end
  end

  defp observed_at(metadata, payload) do
    get_string(payload, ["observed_at"]) ||
      get_string(metadata, ["#{@base}.observed_at"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp get_map(map, keys) do
    case get_value(map, keys) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp get_string(map, keys) do
    case get_value(map, keys) do
      value when is_binary(value) ->
        value |> String.trim() |> blank_to_nil()

      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_float(value) ->
        Float.to_string(value)

      _ ->
        nil
    end
  end

  defp get_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case map do
        %{^key => value} -> value
        _ -> nil
      end
    end)
  end

  defp get_value(_map, _keys), do: nil

  defp parse_number(value) when is_float(value), do: value
  defp parse_number(value) when is_integer(value), do: value / 1

  defp parse_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_number(_value), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
