defmodule ServiceRadarWebNGWeb.Components.DeviceStatsCardsTest do
  @moduledoc false

  # async: false because we start the (globally-named) Endpoint so the `~p`
  # verified routes in the rendered cards resolve without the full application
  # (and its database) running.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.IndexView.Breakdown
  alias ServiceRadarWebNGWeb.DeviceLive.IndexView.Stats, as: DeviceStats

  @moduletag :unit
  @moduletag :db_free

  setup_all do
    case start_supervised(ServiceRadarWebNGWeb.Endpoint) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # The facet overflow used to be an inline dropdown on the card itself, which is what
  # this file originally asserted (all 12 options plus the dropdown's bounding classes).
  # That design is gone -- `max-h-80 overflow-y-auto overflow-x-hidden` occurs nowhere in
  # lib/ any more. The card now summarises, and the full list lives in the breakdown
  # modal. The property worth holding is unchanged: every facet option stays reachable,
  # in a bounded container. It is asserted below against the two halves that now provide
  # it, rather than against markup that no input can produce.
  test "the facet card summarises the top option and offers a control to browse the rest" do
    html =
      render_component(&DeviceStats.device_stats_cards/1, %{
        stats: %{
          total: 24,
          available: 20,
          unavailable: 4,
          by_type: facet_items("Type", 12),
          by_vendor: facet_items("Vendor", 12),
          by_risk_level: [],
          new_today: 2,
          new_last_7d: 5,
          new_last_30d: 9
        },
        loading: false
      })

    # Top option by count, with the remaining 11 signalled rather than listed.
    assert html =~ "Type 1"
    assert html =~ "Vendor 1"
    assert html =~ "+11 more"

    # The control that opens the full list, one per facet kind.
    assert html =~ ~s(phx-click="open_breakdown_modal")
    assert html =~ ~s(phx-value-kind="type")
    assert html =~ ~s(phx-value-kind="vendor")

    # The overflow is deliberately NOT inlined into the card any more.
    refute html =~ "Type 12"
    refute html =~ "Vendor 12"
  end

  test "the new-devices card shows today / 7d / 30d counts and first_seen filters" do
    html =
      render_component(&DeviceStats.device_stats_cards/1, %{
        stats: %{
          total: 103,
          available: 43,
          unavailable: 60,
          by_type: [],
          by_vendor: [],
          by_risk_level: [],
          new_today: 3,
          new_last_7d: 12,
          new_last_30d: 28
        },
        loading: false
      })

    assert html =~ "Devices"
    assert html =~ "today 3"
    assert html =~ "7d 12"
    assert html =~ "30d 28"
    assert html =~ "in:devices first_seen:today"
    assert html =~ "in:devices first_seen:last_7d"
    assert html =~ "in:devices first_seen:last_30d"
  end

  test "the breakdown modal lists every facet option inside a bounded scroll container" do
    items = facet_items("Type", 12)

    html =
      render_component(&Breakdown.breakdown_modal/1, %{
        modal: Breakdown.breakdown_modal_data("By Type", "type", items),
        search: ""
      })

    # Every option is present, not just the top one.
    for %{name: name} <- items do
      assert html =~ name
    end

    # ...and the container is bounded, so 12 (or 1200) options cannot blow out the layout.
    assert html =~ "max-h-[24rem] overflow-y-auto"
    assert html =~ "12 of 12"
  end

  defp facet_items(prefix, count) do
    for index <- 1..count do
      %{name: "#{prefix} #{index}", count: count - index + 1}
    end
  end
end
