defmodule ServiceRadar.EventWriter.Processors.SweepTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.Sweep

  describe "parse_message/1" do
    test "treats successful TCP port results as reachable even when ICMP fails" do
      message = %{
        data:
          Jason.encode!(%{
            "host_ip" => "10.10.10.10",
            "hostname" => "tcp-only-host",
            "gateway_id" => "gateway-1",
            "agent_id" => "agent-1",
            "icmp_available" => false,
            "available" => false,
            "port_results" => [
              %{"port" => 22, "available" => true, "response_time" => 1_000_000}
            ],
            "last_sweep_time" => DateTime.to_iso8601(DateTime.utc_now())
          }),
        metadata: %{subject: "test.sweep.tcp"}
      }

      row = Sweep.parse_message(message)

      assert row.status == "Success"
      assert row.protocol_name == "TCP"
      assert row.protocol_num == 6
      assert row.ports_open == [22]
      assert row.message =~ "reachable"
    end
  end
end
