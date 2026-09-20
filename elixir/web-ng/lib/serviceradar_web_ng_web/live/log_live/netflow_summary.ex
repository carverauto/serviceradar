defmodule ServiceRadarWebNGWeb.LogLive.NetflowSummary do
  @moduledoc """
  The NetFlow summary cards, from one grouped query.

  The per-protocol rows carry the flow, byte and packet sums, and every total
  is the sum of those rows, so the cards cost one round trip. They used to cost
  seven: separate count, bytes and packets queries, three fallbacks for packet
  fields that `packets_total` already resolves on its own, and a per-protocol
  count.
  """

  # IANA protocol numbers fit in one byte, so this cannot drop a row and leave
  # a total short.
  @max_protocols 256

  @type t :: %{
          total: non_neg_integer(),
          tcp: non_neg_integer(),
          udp: non_neg_integer(),
          other: non_neg_integer(),
          total_bytes: non_neg_integer(),
          total_packets: non_neg_integer(),
          avg_bps: float(),
          avg_pps: float(),
          window_seconds: non_neg_integer()
        }

  @doc "The grouped SRQL query for a base `in:flows ...` query."
  @spec query(String.t()) :: String.t()
  def query(base_query) when is_binary(base_query) do
    ~s|#{base_query} stats:"count(*) as total, sum(bytes_total) as total_bytes, | <>
      ~s|sum(packets_total) as total_packets by protocol_num" sort:total:desc limit:#{@max_protocols}|
  end

  @doc "Folds the per-protocol rows into the card values for a window of `window_seconds`."
  @spec from_rows([map()], pos_integer()) :: t()
  def from_rows(rows, window_seconds) when is_list(rows) and is_integer(window_seconds) and window_seconds > 0 do
    total = sum(rows, "total")
    total_bytes = sum(rows, "total_bytes")
    total_packets = sum(rows, "total_packets")
    tcp = protocol_total(rows, 6)
    udp = protocol_total(rows, 17)

    %{
      total: total,
      tcp: tcp,
      udp: udp,
      other: max(total - tcp - udp, 0),
      total_bytes: total_bytes,
      total_packets: total_packets,
      avg_bps: total_bytes * 8.0 / window_seconds,
      avg_pps: total_packets * 1.0 / window_seconds,
      window_seconds: window_seconds
    }
  end

  defp protocol_total(rows, number) do
    rows
    |> Enum.filter(&(to_int(Map.get(&1, "protocol_num")) == number))
    |> sum("total")
  end

  defp sum(rows, field), do: rows |> Enum.map(&to_int(Map.get(&1, field))) |> Enum.sum()

  # The warehouse returns sums as floats and counts as integers; a row from an
  # older backend may carry either as a string.
  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> trunc(number)
      :error -> 0
    end
  end

  defp to_int(_value), do: 0
end
