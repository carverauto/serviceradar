defmodule ServiceRadarWebNGWeb.DeviceLive.CompositeVerdictComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ServiceRadarWebNGWeb.DeviceLive.CompositeVerdictComponents

  defp input(attrs) do
    Map.merge(
      %{
        key: "agent-a",
        label: "agent-a",
        kind: :vantage_point,
        expected: "available",
        value: "available",
        observed_at: DateTime.utc_now(),
        age: "2m ago",
        stale: false,
        reason: nil,
        removed: false
      },
      attrs
    )
  end

  defp entry(attrs) do
    Map.merge(
      %{
        check_id: "11111111-1111-1111-1111-111111111111",
        check_name: "DMZ Isolation",
        check_slug: "dmz-isolation",
        check_state: :enabled,
        verdict: "isolated_verified",
        verdict_label: "Isolated",
        explanation: "Isolation observed from every vantage point",
        status: :healthy,
        evaluated_at: DateTime.utc_now(),
        changed_at: DateTime.utc_now(),
        inputs: [input(%{})]
      },
      attrs
    )
  end

  defp render(entries) do
    render_component(&CompositeVerdictComponents.composite_verdict_section/1, entries: entries)
  end

  test "renders nothing when the device is in no check's scope" do
    assert render([]) =~ ""
    refute render([]) =~ "Composite Checks"
  end

  test "shows the verdict, its status, and the explanation" do
    html = render([entry(%{})])

    assert html =~ ~s(data-composite-check="dmz-isolation")
    assert html =~ ~s(data-composite-verdict="isolated_verified")
    assert html =~ ~s(data-composite-status="healthy")
    assert html =~ "Isolated"
    assert html =~ "Isolation observed from every vantage point"
  end

  test "an unknown input renders its reason, never blank and never raw JSON" do
    html =
      render([
        entry(%{
          inputs: [
            input(%{key: "agent-b", value: "unknown", age: "never", reason: "no_result"})
          ]
        })
      ])

    assert html =~ ~s(data-composite-value="unknown")
    assert html =~ ~s(data-composite-age="never")
    assert html =~ ~s(data-composite-reason="no_result")

    # The snapshot map itself must never reach the page.
    refute html =~ "observed_at"
    refute html =~ "%{"
  end

  test "a stale input is marked stale" do
    html = render([entry(%{inputs: [input(%{stale: true, reason: "stale"})]})])

    assert html =~ "stale"
    assert html =~ ~s(data-composite-reason="stale")
  end

  test "an input removed from the check since the verdict is labelled" do
    html = render([entry(%{inputs: [input(%{key: "agent-gone", removed: true})]})])

    assert html =~ "no longer part of this check"
  end

  test "a non-enabled check's state is shown beside its verdict" do
    html = render([entry(%{check_state: :draft})])

    # A draft's verdict is real but not maintained on a schedule; the badge is
    # what stops it being read as current.
    assert html =~ "draft"
  end

  test "an enabled check shows no state badge" do
    refute render([entry(%{check_state: :enabled})]) =~ "enabled"
  end

  test "the check name links to its builder" do
    html = render([entry(%{})])

    assert html =~ ~s(href="/settings/networks/composite-checks/11111111-1111-1111-1111-111111111111/edit")
  end
end
