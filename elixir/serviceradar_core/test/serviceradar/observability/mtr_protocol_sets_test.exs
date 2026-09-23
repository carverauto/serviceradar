defmodule ServiceRadar.Observability.MtrProtocolSetsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Observability.Changes.SyncBaselineProtocols
  alias ServiceRadar.Observability.MtrAutomationDispatcher
  alias ServiceRadar.Observability.MtrPolicy

  describe "MtrPolicy.protocol_names/1" do
    test "orders a policy's protocol set and drops duplicates" do
      assert MtrPolicy.protocol_names(%{baseline_protocols: [:tcp, :icmp, :tcp]}) == ["icmp", "tcp"]
    end

    test "falls back to the legacy single protocol, then to icmp" do
      assert MtrPolicy.protocol_names(%{baseline_protocols: [], baseline_protocol: "UDP"}) == ["udp"]
      assert MtrPolicy.protocol_names(%{"baseline_protocol" => "tcp"}) == ["tcp"]
      assert MtrPolicy.protocol_names(%{baseline_protocol: "bogus"}) == ["icmp"]
    end

    test "tcp_port/1 keeps a valid port and defaults otherwise" do
      assert MtrPolicy.tcp_port(%{tcp_port: 22}) == 22
      assert MtrPolicy.tcp_port(%{tcp_port: 0}) == 443
      assert MtrPolicy.tcp_port(%{}) == 443
    end
  end

  describe "SyncBaselineProtocols.canonical/1" do
    test "orders icmp, udp, tcp without duplicates" do
      assert SyncBaselineProtocols.canonical([:tcp, :udp, :icmp, :udp]) == [:icmp, :udp, :tcp]
    end
  end

  describe "single-target dispatch payloads" do
    test "one mtr.run payload per protocol, with the port on TCP only" do
      policy = %{baseline_protocols: [:icmp, :tcp], tcp_port: 8443}

      assert MtrAutomationDispatcher.protocol_payloads("192.0.2.10", policy) == [
               %{"target" => "192.0.2.10", "protocol" => "icmp"},
               %{"target" => "192.0.2.10", "protocol" => "tcp", "tcp_port" => 8443}
             ]
    end
  end

  describe "bulk protocol selection" do
    test "an agent that runs protocol sets gets the whole set in canonical order" do
      assert AgentCommandBus.bulk_mtr_protocols("agent-a",
               protocols: ["tcp", "icmp"],
               protocol_set_supported?: true
             ) == ["icmp", "tcp"]
    end

    test "an agent without protocol-set support gets only the first protocol" do
      assert AgentCommandBus.bulk_mtr_protocols("agent-a",
               protocols: ["udp", "tcp", "icmp"],
               protocol_set_supported?: false
             ) == ["icmp"]
    end

    test "a single legacy protocol needs no capability" do
      assert AgentCommandBus.bulk_mtr_protocols("agent-a", protocol: "UDP", protocol_set_supported?: false) ==
               ["udp"]
    end
  end
end
