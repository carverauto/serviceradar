defmodule ServiceRadar.PrefixTags.NativeEngine do
  @moduledoc "Packed native prefix snapshots with bounded construction and immutable reads."
  @behaviour ServiceRadar.PrefixTags.Engine

  alias ServiceRadar.PrefixTags.Native

  @batch_size 2_048
  @optional_fields [:severity, :indicator_count, :expires_at, :feed_sources, :indicators]

  @impl true
  def build(rows) do
    builder = unwrap!(Native.new_builder())

    rows
    |> Stream.flat_map(&normalize_row/1)
    |> Stream.chunk_every(@batch_size)
    |> Enum.each(fn batch -> unwrap!(Native.append(builder, batch)) end)

    unwrap!(Native.finish(builder))
  end

  @impl true
  def lookup(snapshot, ip) do
    case address(ip) do
      {:ok, ip} ->
        snapshot
        |> Native.lookup(ip)
        |> unwrap!()
        |> Enum.map(&decode_entry/1)

      :error ->
        []
    end
  end

  @impl true
  def stats(snapshot), do: unwrap!(Native.stats(snapshot))

  defp normalize_row(row) when is_map(row) do
    with prefix when is_binary(prefix) <- value(row, :prefix),
         {:ok, prefix} <- normalize_prefix(prefix) do
      [
        %{
          prefix: prefix,
          tags: tags(value(row, :tags)),
          source: value(row, :source),
          vrf: value(row, :vrf),
          severity: severity(value(row, :severity)),
          indicator_count: value(row, :indicator_count),
          expires_at: encode_expiry(value(row, :expires_at)),
          feed_sources: value(row, :feed_sources),
          indicators: encode_members(value(row, :indicators))
        }
      ]
    else
      _ -> []
    end
  end

  defp normalize_row(_), do: []

  defp normalize_prefix(prefix) do
    case String.split(String.trim(prefix), "/", parts: 2) do
      [ip] ->
        address(ip)

      [ip, mask] ->
        with {:ok, ip} <- address(ip),
             {length, ""} <- Integer.parse(String.trim(mask)),
             true <- length >= 0 and length <= if(String.contains?(ip, ":"), do: 128, else: 32) do
          {:ok, "#{ip}/#{length}"}
        else
          _ -> :error
        end
    end
  end

  defp address(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(String.trim(ip))) do
      {:ok, tuple} -> address(tuple)
      {:error, _} -> :error
    end
  end

  defp address({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    address(
      {Bitwise.bsr(hi, 8), Bitwise.band(hi, 255), Bitwise.bsr(lo, 8), Bitwise.band(lo, 255)}
    )
  end

  defp address(tuple) when is_tuple(tuple) do
    case :inet.ntoa(tuple) do
      {:error, _} -> :error
      chars -> {:ok, to_string(chars)}
    end
  rescue
    ArgumentError -> :error
  end

  defp address(_), do: :error

  defp value(row, key), do: row[key] || row[Atom.to_string(key)]
  defp tags(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp tags(value) when is_binary(value), do: [value]
  defp tags(_), do: []
  defp severity(value) when is_integer(value) and value >= 0, do: value
  defp severity(_), do: nil

  defp encode_expiry(nil), do: nil

  defp encode_expiry(%DateTime{} = value),
    do: {DateTime.to_unix(value, :microsecond), elem(value.microsecond, 1)}

  defp decode_expiry(nil), do: nil

  defp decode_expiry({micros, precision}) do
    value = DateTime.from_unix!(micros, :microsecond)
    %{value | microsecond: {elem(value.microsecond, 0), precision}}
  end

  defp encode_members(nil), do: nil

  defp encode_members(members) do
    Enum.map(members, fn member ->
      %{
        source: member[:source] || "",
        source_slug: member[:source_slug],
        severity: member[:severity],
        expires_at: encode_expiry(member[:expires_at]),
        indicator_count: member[:indicator_count] || 1,
        tags: member[:tags] || []
      }
    end)
  end

  defp decode_entry(entry) do
    entry
    |> Map.update!(:expires_at, &decode_expiry/1)
    |> Map.update!(:indicators, fn
      nil ->
        nil

      members ->
        Enum.map(members, &Map.update!(&1, :expires_at, fn expiry -> decode_expiry(expiry) end))
    end)
    |> Map.reject(fn {key, value} -> key in @optional_fields and is_nil(value) end)
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: raise("Native prefix snapshot failed: #{reason}")
end
