defmodule ServiceRadarWebNGWeb.Components.DeviceStatsCardsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.Index, as: DeviceIndex

  @moduletag :unit

  test "renders all type and vendor facet options inside a bounded dropdown" do
    by_type = facet_items("Type", 12)
    by_vendor = facet_items("Vendor", 12)

    html =
      render_component(&DeviceIndex.device_stats_cards/1, %{
        stats: %{
          total: 24,
          available: 20,
          unavailable: 4,
          by_type: by_type,
          by_vendor: by_vendor,
          by_risk_level: []
        },
        loading: false
      })

    assert html =~ "Type 12"
    assert html =~ "Vendor 12"
    assert html =~ "max-h-80 overflow-y-auto overflow-x-hidden"
  end

  defp facet_items(prefix, count) do
    for index <- 1..count do
      %{name: "#{prefix} #{index}", count: count - index + 1}
    end
  end
end
