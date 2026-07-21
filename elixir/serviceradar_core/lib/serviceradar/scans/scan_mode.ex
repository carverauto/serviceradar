defmodule ServiceRadar.Scans.ScanMode do
  @moduledoc """
  Scan/sweep modes supported by the ad-hoc scan and sweep engine:

    * `:icmp` - ICMP echo (ping) reachability
    * `:tcp`  - TCP connect probe against the configured ports
    * `:mtr`  - MTR traceroute (first-class sweep mode)
  """

  use Ash.Type.Enum, values: [:icmp, :tcp, :mtr]
end
