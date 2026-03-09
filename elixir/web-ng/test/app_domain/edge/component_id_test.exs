defmodule ServiceRadarWebNG.Edge.ComponentIDTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Edge.ComponentID

  test "prefixes labels that do not already include the component type" do
    assert ComponentID.generate("Production Gateway 01", "gateway") ==
             "gateway-production-gateway-01"
  end

  test "preserves an existing component-type prefix" do
    assert ComponentID.generate("agent-dusk", "agent") == "agent-dusk"
  end

  test "normalizes mixed-case labels before checking the prefix" do
    assert ComponentID.generate("Agent Dusk", :agent) == "agent-dusk"
  end
end
