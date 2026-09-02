defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.Format do
  @moduledoc false

  def iso2_flag_emoji(nil), do: nil

  def iso2_flag_emoji(iso2) when is_binary(iso2) do
    iso2 = iso2 |> String.trim() |> String.upcase()

    if String.length(iso2) == 2 do
      <<a::utf8, b::utf8>> = iso2

      if a in ?A..?Z and b in ?A..?Z do
        # Regional indicator symbols: U+1F1E6 = 'A'
        <<0x1F1E6 + (a - ?A)::utf8, 0x1F1E6 + (b - ?A)::utf8>>
      end
    end
  end

  def iso2_flag_emoji(_), do: nil

  def tcp_flag_tooltip(flag) when is_binary(flag) do
    case String.upcase(String.trim(flag)) do
      "SYN" -> "SYN: Starts a TCP connection."
      "ACK" -> "ACK: Acknowledges received data."
      "FIN" -> "FIN: Requests a graceful connection close."
      "RST" -> "RST: Abruptly resets the connection."
      "PSH" -> "PSH: Pushes buffered data to the application immediately."
      "URG" -> "URG: Marks urgent data in this segment."
      "ECE" -> "ECE: Signals Explicit Congestion Notification."
      "CWR" -> "CWR: Confirms congestion window was reduced."
      "NS" -> "NS: ECN nonce protection flag (rare)."
      _ -> "TCP flag."
    end
  end

  def tcp_flag_tooltip(_), do: "TCP flag."

  def to_float(v) when is_integer(v), do: v * 1.0
  def to_float(v) when is_float(v), do: v

  def to_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> f
      _ -> 0.0
    end
  end

  def to_float(_), do: 0.0

  def to_number(value) when is_number(value), do: value

  def to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {f, ""} -> f
      _ -> 0
    end
  end

  def to_number(_), do: 0

  def to_int(value) when is_integer(value), do: value
  def to_int(value) when is_float(value), do: trunc(value)

  def to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {i, ""} ->
        i

      _ ->
        # SRQL may serialize aggregates as float strings (e.g. "123.0" or "1.23e4").
        case Float.parse(value) do
          {f, ""} -> trunc(f)
          _ -> 0
        end
    end
  end

  def to_int(_), do: 0

  def flows_table_traffic_header("pps"), do: "Packets"
  def flows_table_traffic_header("bps"), do: "Packets / Bits"
  def flows_table_traffic_header(_), do: "Packets / Bytes"

  def format_bits_parts(nil), do: {"—", ""}
  def format_bits_parts(""), do: {"—", ""}

  def format_bits_parts(value) do
    bits = to_int(value) * 8
    abs_bits = abs(bits)

    cond do
      abs_bits >= 1024 * 1024 * 1024 ->
        {format_float(bits / (1024 * 1024 * 1024)), "Gb"}

      abs_bits >= 1024 * 1024 ->
        {format_float(bits / (1024 * 1024)), "Mb"}

      abs_bits >= 1024 ->
        {format_float(bits / 1024), "Kb"}

      true ->
        {Integer.to_string(bits), "b"}
    end
  rescue
    _ -> {"—", ""}
  end

  def format_bytes_parts(nil), do: {"—", ""}
  def format_bytes_parts(""), do: {"—", ""}

  def format_bytes_parts(value) do
    bytes = to_int(value)
    abs_bytes = abs(bytes)

    cond do
      abs_bytes >= 1024 * 1024 * 1024 ->
        {format_float(bytes / (1024 * 1024 * 1024)), "GB"}

      abs_bytes >= 1024 * 1024 ->
        {format_float(bytes / (1024 * 1024)), "MB"}

      abs_bytes >= 1024 ->
        {format_float(bytes / 1024), "KB"}

      true ->
        {Integer.to_string(bytes), "B"}
    end
  rescue
    _ -> {"—", ""}
  end

  def format_float(v) when is_float(v) do
    # Compact but readable for table cells.
    if abs(v) >= 10.0,
      do: :erlang.float_to_binary(v, decimals: 1),
      else: :erlang.float_to_binary(v, decimals: 2)
  end
end
