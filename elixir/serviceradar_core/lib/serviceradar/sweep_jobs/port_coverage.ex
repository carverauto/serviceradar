defmodule ServiceRadar.SweepJobs.PortCoverage do
  @moduledoc """
  Pure derivation of per-host port coverage from an agent sweep result.

  `open_ports` records the ports that answered. `scanned_ports` records every
  port the sweep attempted, so a refused port is distinguishable from a port
  that was never tried at all. Closed and no-response ports are not stored:
  they are `scanned_ports` minus `open_ports`, derived at read time.

  Coverage is taken only from the agent payload. It is deliberately not seeded
  from the sweep group's configured ports, because the configured set is what
  was requested and this value is what was attempted; merging them would erase
  the distinction.
  """

  @min_port 1
  @max_port 65_535

  @doc """
  Every port the agent reported attempting, sorted and deduplicated.

  Returns `[]` for an ICMP-only result or a payload with no port data.
  """
  @spec scanned_ports(map()) :: [pos_integer()]
  def scanned_ports(result) when is_map(result) do
    (reported_ports(result) ++ open_ports(result))
    |> Enum.map(&parse_port/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def scanned_ports(_result), do: []

  defp reported_ports(result) do
    case port_results(result) do
      entries when is_list(entries) -> Enum.map(entries, &entry_port/1)
      _ -> []
    end
  end

  defp port_results(result) do
    result["port_results"] || result["port_scan_results"] || result["portScanResults"]
  end

  defp entry_port(entry) when is_map(entry), do: entry["port"] || entry[:port]
  defp entry_port(_entry), do: nil

  # An open port was necessarily attempted, so it counts as coverage even when
  # the payload omits the per-port detail.
  defp open_ports(result) do
    case result["tcp_ports_open"] || result["tcpPortsOpen"] do
      ports when is_list(ports) -> ports
      _ -> []
    end
  end

  defp parse_port(value) when is_integer(value), do: valid_port(value)

  defp parse_port(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> valid_port(parsed)
      _ -> nil
    end
  end

  defp parse_port(_value), do: nil

  defp valid_port(port) when port >= @min_port and port <= @max_port, do: port
  defp valid_port(_port), do: nil
end
