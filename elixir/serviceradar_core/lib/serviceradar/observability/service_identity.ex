defmodule ServiceRadar.Observability.ServiceIdentity do
  @moduledoc false

  import Bitwise

  @namespace "serviceradar-service-v1"

  @spec service_id(map() | keyword() | nil) :: String.t()
  def service_id(attrs) when is_map(attrs) or is_list(attrs) do
    agent_id = normalize(fetch(attrs, :agent_id), "unknown")
    gateway_id = normalize(fetch(attrs, :gateway_id), "unknown")
    partition = normalize(fetch(attrs, :partition), "default")
    service_type = normalize(fetch(attrs, :service_type), "unknown")
    service_name = normalize(fetch(attrs, :service_name), "unknown")

    seed =
      Enum.join(
        [
          "agent:#{agent_id}",
          "gateway:#{gateway_id}",
          "partition:#{partition}",
          "type:#{service_type}",
          "name:#{service_name}"
        ],
        "|"
      )

    uuid_from_hash(:crypto.hash(:sha256, "#{@namespace}:#{seed}"))
  end

  def service_id(_), do: "00000000-0000-0000-0000-000000000000"

  defp fetch(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp fetch(attrs, key) when is_list(attrs) do
    Keyword.get(attrs, key) || Keyword.get(attrs, Atom.to_string(key))
  end

  defp fetch(_attrs, _key), do: nil

  defp normalize(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: fallback, else: trimmed
  end

  defp normalize(nil, fallback), do: fallback
  defp normalize(value, _fallback), do: to_string(value)

  defp uuid_from_hash(hash_bytes) when is_binary(hash_bytes) and byte_size(hash_bytes) >= 16 do
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> = hash_bytes

    # Set version (5) and variant (RFC 4122)
    c_versioned = (c &&& 0x0FFF) ||| 0x5000
    d_variant = (d &&& 0x3FFF) ||| 0x8000

    "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
    |> :io_lib.format([
      a,
      b,
      c_versioned,
      d_variant,
      e
    ])
    |> IO.iodata_to_binary()
    |> String.downcase()
  end

  defp uuid_from_hash(_), do: "00000000-0000-0000-0000-000000000000"
end
