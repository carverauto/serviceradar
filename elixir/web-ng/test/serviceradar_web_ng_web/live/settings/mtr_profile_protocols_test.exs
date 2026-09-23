defmodule ServiceRadarWebNGWeb.Settings.MtrProfilesLive.ProtocolsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.MtrComponents
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrCompare
  alias ServiceRadarWebNGWeb.Settings.MtrProfilesLive.Protocols

  @moduletag :db_free

  describe "Protocols.from_params/1" do
    test "reads the checkbox group in canonical order, ignoring the hidden blank" do
      assert Protocols.from_params(%{"baseline_protocols" => ["", "tcp", "icmp"]}) == ["icmp", "tcp"]
    end

    test "an empty selection stays empty so the form can reject it" do
      assert Protocols.from_params(%{"baseline_protocols" => [""]}) == []
    end

    test "older params with a single protocol still count" do
      assert Protocols.from_params(%{"baseline_protocol" => "UDP"}) == ["udp"]
    end

    test "count/1 is at least one" do
      assert Protocols.count(%{"baseline_protocols" => ["icmp", "udp", "tcp"]}) == 3
      assert Protocols.count(%{"baseline_protocols" => [""]}) == 1
    end
  end

  describe "Protocols.label/1" do
    test "joins the set and shows the TCP port" do
      assert Protocols.label(%{baseline_protocols: [:icmp, :tcp], tcp_port: 443}) == "ICMP + TCP (TCP 443)"
      assert Protocols.label(%{baseline_protocols: [:udp]}) == "UDP"
    end
  end

  describe "device tab latest trace per protocol" do
    test "keeps the newest trace of each protocol in icmp/udp/tcp order" do
      traces = [
        %{"id" => "t3", "protocol" => "tcp"},
        %{"id" => "i2", "protocol" => "icmp"},
        %{"id" => "t1", "protocol" => "tcp"},
        %{"id" => "i1", "protocol" => "icmp"}
      ]

      assert Enum.map(MtrComponents.latest_trace_by_protocol(traces), & &1["id"]) == ["i2", "t3"]
    end
  end

  describe "compare mixed-protocol warning" do
    test "flags traces taken with different protocols" do
      assert MtrCompare.mixed_protocols?(%{"protocol" => "icmp"}, %{"protocol" => "tcp"})
      refute MtrCompare.mixed_protocols?(%{"protocol" => "TCP"}, %{"protocol" => "tcp"})
      refute MtrCompare.mixed_protocols?(nil, %{"protocol" => "tcp"})
    end
  end
end
