defmodule ServiceRadar.FlowAttribution.EventRowsTest do
  use ExUnit.Case, async: true

  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent
  alias ServiceRadar.FlowAttribution.EventRows

  test "attribution_key is socket-scoped (ignores pid/comm/container)" do
    base = %FlowAttributionEvent{
      local_ip: "10.42.0.1",
      local_port: 4000,
      remote_ip: "0.0.0.0",
      remote_port: 0,
      transport_protocol: "tcp",
      pid: 1787,
      tgid: 1787,
      uid: 0,
      gid: 0,
      comm: "k3s-agent",
      redacted_cmdline: ["/usr/local/bin/k3s"],
      container_id: "",
      observed_at_unix_nano: System.system_time(:nanosecond)
    }

    host = EventRows.from_event(base, "default", "agent-a")

    container =
      EventRows.from_event(
        %{base | pid: 99, comm: "beam.smp", container_id: String.duplicate("a", 64)},
        "default",
        "agent-a"
      )

    assert host.attribution_key == container.attribution_key
    assert host.pid == 1787
    assert container.pid == 99
  end
end
