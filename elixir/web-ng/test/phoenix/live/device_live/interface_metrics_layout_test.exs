defmodule ServiceRadarWebNGWeb.DeviceLive.InterfaceMetricsLayoutTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceComponents

  @moduletag :db_free

  test "favorited traffic and packet charts stack as full-width rows rather than a nested grid" do
    class = InterfaceComponents.favorited_metrics_stack_class()
    assert class =~ "flex"
    assert class =~ "flex-col"
    assert class =~ "w-full"
    refute class =~ "auto-fit"
    refute class =~ "grid-cols"
  end
end
