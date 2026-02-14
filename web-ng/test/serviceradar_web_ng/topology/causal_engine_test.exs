defmodule ServiceRadarWebNG.Topology.CausalEngineTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.CausalEngine

  test "selects deterministic root and propagates affected nodes" do
    nodes = [
      %{id: "a", health_signal: :unhealthy},
      %{id: "b", health_signal: :unhealthy},
      %{id: "c", health_signal: :healthy},
      %{id: "d", health_signal: :healthy}
    ]

    edges = [
      %{source: "a", target: "c"},
      %{source: "b", target: "c"},
      %{source: "b", target: "d"}
    ]

    states = CausalEngine.evaluate(nodes, edges)

    assert states["b"] == 0
    assert states["a"] == 1
    assert states["c"] == 1
    assert states["d"] == 1
  end

  test "falls back to healthy and unknown when no root-cause signal is present" do
    nodes = [
      %{id: "a", health_signal: :healthy},
      %{id: "b", health_signal: :unknown},
      %{id: "c"}
    ]

    states = CausalEngine.evaluate(nodes, [])

    assert states["a"] == 2
    assert states["b"] == 3
    assert states["c"] == 3
  end
end
