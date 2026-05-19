defmodule ServiceRadar.Core.ResultProcessorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Core.ResultProcessor

  describe "process_host_results/2" do
    test "marks host available when ICMP succeeds even if aggregate available is false" do
      [update] =
        ResultProcessor.process_host_results(
          [
            %{
              "host" => "10.0.0.1",
              "available" => false,
              "icmp_status" => %{"available" => true, "round_trip_ns" => 5_000_000}
            }
          ],
          gateway_id: "gateway-1",
          partition: "default",
          agent_id: "agent-1",
          resolve_identities: false
        )

      assert update.is_available == true
    end

    test "marks host available when TCP succeeds even if aggregate available is false" do
      [update] =
        ResultProcessor.process_host_results(
          [
            %{
              "host" => "10.0.0.1",
              "available" => false,
              "icmp_status" => %{"available" => false},
              "port_results" => [
                %{"port" => 22, "available" => false},
                %{"port" => 443, "available" => true}
              ]
            }
          ],
          gateway_id: "gateway-1",
          partition: "default",
          agent_id: "agent-1",
          resolve_identities: false
        )

      assert update.is_available == true
      assert update.metadata["open_port_count"] == "1"
      assert update.metadata["open_ports"] == "[443]"
    end

    test "marks host available from flattened TCP open ports" do
      [update] =
        ResultProcessor.process_host_results(
          [
            %{
              "host" => "10.0.0.1",
              "available" => false,
              "icmp_status" => %{"available" => false},
              "tcp_ports_open" => [445, "3389"]
            }
          ],
          gateway_id: "gateway-1",
          partition: "default",
          agent_id: "agent-1",
          resolve_identities: false
        )

      assert update.is_available == true
      assert update.metadata["open_port_count"] == "2"
      assert update.metadata["open_ports"] == "[445,3389]"
    end
  end
end
