defmodule ServiceRadarWebNG.Topology.BitmapAddress do
  @moduledoc "Numeric host and CIDR normalization at the typed bitmap boundary; never resolves names."

  import Bitwise

  @doc "Assigned inventory addresses retain host bits, discard zone/CIDR suffixes, and unmap IPv4."
  def source(value) when is_binary(value) and byte_size(value) <= 256 do
    with true <- String.valid?(value),
         host = value |> String.trim() |> String.split(["%", "/"], parts: 2) |> hd(),
         {:ok, address} <- address(host) do
      {packed, _mapped?} = pack(address)
      {:ok, packed}
    else
      _ -> {:error, :invalid_address}
    end
  end

  def source(_value), do: {:error, :invalid_address}

  @doc "Canonical network bytes and mask length for a literal IPv4/IPv6 query."
  def cidr(value) when is_binary(value) and byte_size(value) in 1..256 do
    if String.valid?(value) do
      case String.split(String.trim(value), "/", parts: 2) do
        [host] -> network(host, nil)
        [host, mask] -> network(host, mask)
      end
    else
      {:error, :invalid_cidr}
    end
  end

  def cidr(_value), do: {:error, :invalid_cidr}

  defp network(host, mask) do
    with {:ok, address} <- address(host),
         {:ok, length} <- mask(mask, if(tuple_size(address) == 4, do: 32, else: 128)),
         {packed, mapped?} = pack(address),
         true <- not mapped? or length >= 96 do
      length = if mapped?, do: length - 96, else: length
      bits = byte_size(packed) * 8
      <<number::unsigned-big-size(bits)>> = packed
      network = (number >>> (bits - length)) <<< (bits - length)
      {:ok, <<network::unsigned-big-size(bits)>>, length}
    else
      _ -> {:error, :invalid_cidr}
    end
  end

  defp address(host) do
    if String.valid?(host) and not String.contains?(host, "%") do
      case :inet.parse_strict_address(String.to_charlist(host)) do
        {:ok, address} -> {:ok, address}
        _ -> {:error, :invalid_address}
      end
    else
      {:error, :invalid_address}
    end
  end

  defp mask(nil, maximum), do: {:ok, maximum}

  defp mask(value, maximum) do
    if Regex.match?(~r/^\d{1,3}$/, value) do
      case Integer.parse(value) do
        {length, ""} when length >= 0 and length <= maximum -> {:ok, length}
        _ -> {:error, :invalid_cidr}
      end
    else
      {:error, :invalid_cidr}
    end
  end

  defp pack({a, b, c, d}), do: {<<a, b, c, d>>, false}
  defp pack({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: {<<hi::16, lo::16>>, true}
  defp pack({a, b, c, d, e, f, g, h}), do: {<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>, false}
end
