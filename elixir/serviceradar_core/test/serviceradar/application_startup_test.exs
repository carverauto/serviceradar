defmodule ServiceRadar.ApplicationStartupTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "critical applications are started" do
    apps = Application.started_applications() |> Enum.map(&elem(&1, 0))

    assert :telemetry in apps
    assert :ash_state_machine in apps
  end
end
