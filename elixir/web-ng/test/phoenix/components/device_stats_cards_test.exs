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

  test "the availability counts link to the canonical state, Unknown included" do
    document =
      (&DeviceStats.device_stats_cards/1)
      |> render_component(%{
        stats: %{total: 10, available: 6, unavailable: 3, unknown: 1, by_type: [], by_vendor: []},
        loading: false
      })
      |> LazyHTML.from_fragment()

    for {state, count} <- [available: "6", unavailable: "3", unknown: "1"] do
      card = LazyHTML.query(document, "#device-stats-#{state}")

      assert LazyHTML.attribute(card, "href") == ["/devices?q=in:devices availability:#{state}"]
      assert card |> LazyHTML.text() |> String.contains?(count)
    end
  end

  test "the breakdown browser receives every canonical value and an escaped navigation target" do
    items = [%{name: ~s(Example "Quoted" Vendor), count: 7} | facet_items("Vendor", 60)]

    html =
      render_component(&Breakdown.breakdown_modal/1, %{
        modal: Breakdown.breakdown_modal_data("By Vendor", "vendor_name", items)
      })

    [encoded] = html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-items]") |> LazyHTML.attribute("data-items")
    values = Jason.decode!(encoded)
    assert length(values) == 61
    assert %{"value" => ~s(Example "Quoted" Vendor), "count" => 7, "href" => href} = hd(values)
    assert URI.decode(href) == ~S(/devices?q=in:devices vendor_name:"Example \"Quoted\" Vendor")
    assert List.last(values)["value"] == "Vendor 60"
  end

  defp facet_items(prefix, count) do
    for index <- 1..count do
      %{name: "#{prefix} #{index}", count: count - index + 1}
    end
  end
end
