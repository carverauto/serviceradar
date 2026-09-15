defmodule ServiceRadarWebNGWeb.DeviceLive.AvailabilityComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ServiceRadarWebNGWeb.DeviceLive.AvailabilityComponents

  @moduletag :db_free

  test "online, offline and unknown buckets have visible theme colors and explicit coverage" do
    availability = %{
      uptime_pct: 50.0,
      total_checks: 2,
      online_checks: 1,
      offline_checks: 1,
      unknown_checks: 1,
      segments: Enum.map([:online, :offline, :unknown], &segment/1)
    }

    document = render(availability)

    assert [online] = document |> LazyHTML.query("[data-availability-status=online]") |> LazyHTML.attribute("class")
    assert online =~ "bg-[var(--color-success)]"
    assert [offline] = document |> LazyHTML.query("[data-availability-status=offline]") |> LazyHTML.attribute("class")
    assert offline =~ "bg-[var(--color-error)]"
    assert [unknown] = document |> LazyHTML.query("[data-availability-status=unknown]") |> LazyHTML.attribute("class")
    assert unknown =~ "bg-sr-line-strong"
    assert document |> LazyHTML.query("#device-availability-percent") |> LazyHTML.text() |> String.trim() == "50.0%"
    assert LazyHTML.text(document) =~ "online among observed buckets"
    assert LazyHTML.text(document) =~ "2 observed of 3 buckets"
  end

  test "unknown-only coverage does not present a healthy percentage" do
    document =
      render(%{
        uptime_pct: nil,
        total_checks: 0,
        unknown_checks: 48,
        segments: List.duplicate(segment(:unknown), 48)
      })

    assert document |> LazyHTML.query("#device-availability-percent") |> LazyHTML.text() |> String.trim() == "—"

    assert document |> LazyHTML.query("[data-availability-status=unknown]") |> LazyHTML.attribute("title") |> length() ==
             48

    assert LazyHTML.text(document) =~ "0 observed of 48 buckets"
  end

  defp render(availability) do
    (&AvailabilityComponents.availability_section/1)
    |> render_component(availability: availability)
    |> LazyHTML.from_fragment()
  end

  defp segment(status) do
    %{status: status, width: 1.0, title: "Synthetic #{status} bucket", timestamp: "2000-01-01T00:00:00Z"}
  end
end
