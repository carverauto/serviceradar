defmodule ServiceRadarWebNGWeb.Components.UserTimeTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.CoreComponents

  @moduletag :unit
  @moduletag :db_free

  test "renders semantic canonical UTC metadata with a deterministic fallback" do
    html =
      render_component(&CoreComponents.user_time/1, %{
        id: "event-created-at",
        value: ~U[2026-08-30 18:00:00Z],
        timezone: "America/Chicago",
        style: :full
      })

    time = LazyHTML.query(LazyHTML.from_fragment(html), "time")

    assert LazyHTML.tag(time) == ["time"]
    assert LazyHTML.attribute(time, "id") == ["event-created-at"]
    assert LazyHTML.attribute(time, "datetime") == ["2026-08-30T18:00:00Z"]
    assert LazyHTML.attribute(time, "data-user-time-iso") == ["2026-08-30T18:00:00Z"]
    assert LazyHTML.attribute(time, "data-user-time-zone") == ["America/Chicago"]
    assert LazyHTML.attribute(time, "data-user-time-style") == ["full"]
    assert LazyHTML.attribute(time, "phx-hook") == ["UserTime"]
    assert LazyHTML.attribute(time, "title") == ["2026-08-30T18:00:00Z (UTC); display zone America/Chicago"]
    assert LazyHTML.attribute(time, "aria-label") == ["2026-08-30T18:00:00Z UTC; display zone America/Chicago"]
    assert LazyHTML.text(time) == "2026-08-30T18:00:00Z"
  end

  test "preserves fractional canonical UTC precision in metadata and fallback text" do
    html =
      render_component(&CoreComponents.user_time/1, %{
        id: "event-observed-at",
        value: ~U[2026-08-30 18:00:00.123456Z],
        timezone: "America/Chicago"
      })

    time = LazyHTML.query(LazyHTML.from_fragment(html), "time")
    canonical = "2026-08-30T18:00:00.123456Z"

    assert LazyHTML.attribute(time, "datetime") == [canonical]
    assert LazyHTML.attribute(time, "data-user-time-iso") == [canonical]
    assert LazyHTML.attribute(time, "title") == ["#{canonical} (UTC); display zone America/Chicago"]
    assert LazyHTML.attribute(time, "aria-label") == ["#{canonical} UTC; display zone America/Chicago"]
    assert LazyHTML.text(time) == canonical
  end

  test "normalizes a DateTime value to canonical UTC metadata" do
    {:ok, value, _offset} = DateTime.from_iso8601("2026-08-30T13:00:00.123456-05:00")

    html =
      render_component(&CoreComponents.user_time/1, %{
        id: "offset-observed-at",
        value: value,
        timezone: "America/Chicago"
      })

    time = LazyHTML.query(LazyHTML.from_fragment(html), "time")
    canonical = "2026-08-30T18:00:00.123456Z"

    assert LazyHTML.attribute(time, "datetime") == [canonical]
    assert LazyHTML.attribute(time, "data-user-time-iso") == [canonical]
    assert LazyHTML.text(time) == canonical
  end

  test "renders caller fallback without a hook for nil and invalid values" do
    nil_html =
      render_component(&CoreComponents.user_time/1, %{
        id: "missing-created-at",
        value: nil,
        timezone: "America/Chicago",
        fallback: "Not recorded"
      })

    invalid_html =
      render_component(&CoreComponents.user_time/1, %{
        id: "invalid-created-at",
        value: "not-a-timestamp",
        timezone: "America/Chicago"
      })

    nil_fallback = LazyHTML.query(LazyHTML.from_fragment(nil_html), "span")
    invalid_fallback = LazyHTML.query(LazyHTML.from_fragment(invalid_html), "span")

    assert LazyHTML.text(nil_fallback) == "Not recorded"
    assert LazyHTML.text(invalid_fallback) == "—"
    assert nil_html |> LazyHTML.from_fragment() |> LazyHTML.query("time") |> LazyHTML.tag() == []
    assert invalid_html |> LazyHTML.from_fragment() |> LazyHTML.query("time") |> LazyHTML.tag() == []
    refute nil_html =~ "phx-hook"
    refute invalid_html =~ "phx-hook"
  end

  test "renders Etc/UTC correctly without browser localization" do
    html =
      render_component(&CoreComponents.user_time/1, %{
        id: "utc-created-at",
        value: ~U[2026-08-30 18:00:00Z],
        timezone: "Etc/UTC",
        style: :compact
      })

    time = LazyHTML.query(LazyHTML.from_fragment(html), "time")

    assert LazyHTML.attribute(time, "data-user-time-zone") == ["Etc/UTC"]
    assert LazyHTML.text(time) == "2026-08-30T18:00:00Z"
  end
end
