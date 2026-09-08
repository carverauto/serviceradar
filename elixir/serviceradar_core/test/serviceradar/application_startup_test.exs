defmodule ServiceRadar.ApplicationStartupTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "critical applications are started" do
    apps = Enum.map(Application.started_applications(), &elem(&1, 0))

    assert :telemetry in apps
    assert :ash_state_machine in apps
  end
end
