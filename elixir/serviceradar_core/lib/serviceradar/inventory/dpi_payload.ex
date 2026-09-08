defmodule ServiceRadar.Inventory.DpiPayload do
  @moduledoc false

  @base "dpi"

  @spec enrich_metadata(map()) :: map()
  def enrich_metadata(metadata) when is_map(metadata) do
    nested = get_map(metadata, [@base, :dpi])

    enriched =
      metadata
      |> observed_protocols(nested)
      |> Enum.reduce(nested, fn protocol, acc ->
        payload = protocol_payload(metadata, nested, protocol)

        if map_size(payload) == 0 do
          acc
        else
          Map.put(acc, protocol, payload)
        end
      end)

    if map_size(enriched) == 0 do
      metadata
    else
      Map.put(metadata, @base, enriched)
    end
  end

  def enrich_metadata(_metadata), do: %{}

  defp observed_protocols(metadata, nested) do
    nested_protocols =
      nested
      |> Map.keys()
      |> Enum.flat_map(&protocol_name/1)

    flat_protocols =
      metadata
      |> Map.keys()
      |> Enum.flat_map(fn
        key when is_binary(key) ->
          case String.split(key, ".", parts: 3) do
            [@base, protocol, _field] -> protocol_name(protocol)
            _ -> []
          end

        _ ->
          []
      end)

    explicit =
      metadata
      |> get_string(["#{@base}.protocol"])
      |> protocol_name()

    Enum.uniq(nested_protocols ++ flat_protocols ++ explicit)
  end

  defp protocol_payload(metadata, nested, protocol) do
    nested_protocol = get_protocol_map(nested, protocol)

    %{}
    |> maybe_put("count", dpi_integer(metadata, nested_protocol, protocol, "count"))
    |> maybe_put("confidence", dpi_number(metadata, nested_protocol, protocol, "confidence"))
    |> maybe_put(
      "last_observed_at",
      get_string(nested_protocol, ["last_observed_at"]) ||
        get_string(metadata, ["#{@base}.#{protocol}.last_observed_at", "#{@base}.observed_at"])
    )
  end

  defp dpi_integer(metadata, nested_protocol, protocol, field) do
    metadata
    |> get_value(["#{@base}.#{protocol}.#{field}"])
    |> parse_integer()
    |> case do
      nil ->
        nested_protocol
        |> get_value([field])
        |> parse_integer()

      value ->
        value
    end
  end

  defp dpi_number(metadata, nested_protocol, protocol, field) do
    metadata
    |> get_value(["#{@base}.#{protocol}.#{field}"])
    |> parse_number()
    |> case do
      nil ->
        nested_protocol
        |> get_value([field])
        |> parse_number()

      value ->
        value
    end
  end

  defp protocol_name(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.downcase()

    if value == "", do: [], else: [value]
  end

  defp protocol_name(value) when is_atom(value), do: protocol_name(Atom.to_string(value))
  defp protocol_name(_value), do: []

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp get_map(map, keys) do
    case get_value(map, keys) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp get_protocol_map(map, protocol) when is_map(map) do
    get_map(map, [protocol, protocol_atom(protocol)])
  end

  defp protocol_atom("http1"), do: :http1
  defp protocol_atom("http2"), do: :http2
  defp protocol_atom("tls"), do: :tls
  defp protocol_atom("dns"), do: :dns
  defp protocol_atom("ssh"), do: :ssh
  defp protocol_atom("ftp"), do: :ftp
  defp protocol_atom("quic"), do: :quic
  defp protocol_atom("mqtt"), do: :mqtt
  defp protocol_atom("bittorrent"), do: :bittorrent
  defp protocol_atom(_protocol), do: nil

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

  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(value) when is_float(value), do: trunc(value)

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

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
