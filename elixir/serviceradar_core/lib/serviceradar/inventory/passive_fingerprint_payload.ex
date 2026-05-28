defmodule ServiceRadar.Inventory.PassiveFingerprintPayload do
  @moduledoc false

  @base "passive_fingerprint"
  @fingerprint_source "serviceradar-license-clean"
  @protocol_atoms %{"tcp" => :tcp, "tls" => :tls, "http" => :http}

  @spec enrich_metadata(map()) :: map()
  def enrich_metadata(metadata) when is_map(metadata) do
    nested = get_map(metadata, [@base, :passive_fingerprint])

    enriched =
      nested
      |> put_protocol("tcp", tcp_payload(metadata, nested), metadata)
      |> put_protocol("tls", tls_payload(metadata, nested), metadata)
      |> put_protocol("http", http_payload(metadata, nested), metadata)

    if map_size(enriched) == 0 do
      metadata
    else
      Map.put(metadata, @base, enriched)
    end
  end

  def enrich_metadata(_metadata), do: %{}

  @spec enrich_os(map(), map()) :: map()
  def enrich_os(os, metadata) when is_map(os) and is_map(metadata) do
    case os_payload(metadata) do
      nil -> os
      payload -> Map.put(os, @base, payload)
    end
  end

  def enrich_os(_os, metadata) when is_map(metadata), do: enrich_os(%{}, metadata)
  def enrich_os(os, _metadata) when is_map(os), do: os
  def enrich_os(_os, _metadata), do: %{}

  defp tcp_payload(metadata, nested) do
    tcp = get_map(nested, ["tcp", :tcp])
    observed_at = observed_at(metadata, tcp)
    signature = passive_string(metadata, tcp, "tcp.signature", ["signature", "p0f_signature"])

    %{}
    |> maybe_put("p0f_signature", signature)
    |> maybe_put("signature", signature)
    |> maybe_put("os_family", passive_string(metadata, tcp, "tcp.os_family", ["os_family"]))
    |> maybe_put("os_name", passive_string(metadata, tcp, "tcp.os_name", ["os_name"]))
    |> maybe_put(
      "confidence",
      passive_number(metadata, tcp, "tcp.confidence", ["confidence"])
    )
    |> merge_common_payload(metadata, observed_at)
  end

  defp tls_payload(metadata, nested) do
    tls = get_map(nested, ["tls", :tls])
    observed_at = observed_at(metadata, tls)

    %{}
    |> maybe_put("ja4", passive_string(metadata, tls, "tls.ja4", ["ja4"]))
    |> maybe_put("ja4s", passive_string(metadata, tls, "tls.ja4s", ["ja4s"]))
    |> maybe_put(
      "sni_redacted",
      passive_string(metadata, tls, "tls.sni_redacted", ["sni_redacted"])
    )
    |> merge_common_payload(metadata, observed_at)
  end

  defp http_payload(metadata, nested) do
    http = get_map(nested, ["http", :http])
    observed_at = observed_at(metadata, http)

    %{}
    |> maybe_put("user_agent", passive_string(metadata, http, "http.user_agent", ["user_agent"]))
    |> maybe_put("server", passive_string(metadata, http, "http.server", ["server"]))
    |> maybe_put(
      "accept_language",
      passive_string(metadata, http, "http.accept_language", ["accept_language"])
    )
    |> merge_common_payload(metadata, observed_at)
  end

  defp os_payload(metadata) do
    nested = get_map(metadata, [@base, :passive_fingerprint])
    tcp = get_map(nested, ["tcp", :tcp])

    family = passive_string(metadata, tcp, "tcp.os_family", ["os_family"])
    version = passive_string(metadata, tcp, "tcp.os_name", ["os_name"])

    %{}
    |> maybe_put("family", family)
    |> maybe_put("version", version)
    |> maybe_put("confidence", passive_number(metadata, tcp, "tcp.confidence", ["confidence"]))
    |> maybe_put("source", @fingerprint_source)
    |> maybe_put("observed_at", observed_at(metadata, tcp))
    |> case do
      payload
      when is_map_key(payload, "family") or is_map_key(payload, "version") or
             is_map_key(payload, "confidence") ->
        payload

      _ ->
        nil
    end
  end

  defp merge_common_payload(payload, metadata, observed_at) do
    payload
    |> maybe_put("source", get_string(metadata, ["#{@base}.source", "#{@base}.protocol_source"]))
    |> maybe_put("profile_id", get_string(metadata, ["#{@base}.profile_id"]))
    |> maybe_put("profile_name", get_string(metadata, ["#{@base}.profile_name"]))
    |> maybe_put("interface", get_string(metadata, ["#{@base}.interface"]))
    |> maybe_put("observed_at", observed_at)
  end

  defp put_protocol(nested, protocol, payload, metadata) when map_size(payload) == 0 do
    if protocol_observed?(nested, metadata, protocol) do
      Map.put(nested, protocol, %{"observed" => true})
    else
      nested
    end
  end

  defp put_protocol(nested, protocol, payload, _metadata), do: Map.put(nested, protocol, payload)

  defp protocol_observed?(nested, metadata, protocol) do
    Map.has_key?(nested, protocol) ||
      Map.has_key?(nested, Map.fetch!(@protocol_atoms, protocol)) ||
      flat_protocol_observed?(metadata, protocol)
  end

  defp flat_protocol_observed?(metadata, protocol) when is_map(metadata) do
    prefix = "#{@base}.#{protocol}."

    metadata
    |> Map.keys()
    |> Enum.any?(fn
      key when is_binary(key) -> String.starts_with?(key, prefix)
      _key -> false
    end)
  end

  defp flat_protocol_observed?(_metadata, _protocol), do: false

  defp passive_string(metadata, nested_protocol, suffix, nested_keys) do
    get_string(metadata, ["#{@base}.#{suffix}"]) || get_string(nested_protocol, nested_keys)
  end

  defp passive_number(metadata, nested_protocol, suffix, nested_keys) do
    metadata
    |> get_value(["#{@base}.#{suffix}"])
    |> parse_number()
    |> case do
      nil ->
        nested_protocol
        |> get_value(nested_keys)
        |> parse_number()

      value ->
        value
    end
  end

  defp observed_at(metadata, protocol_payload) do
    get_string(protocol_payload, ["observed_at"]) ||
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
