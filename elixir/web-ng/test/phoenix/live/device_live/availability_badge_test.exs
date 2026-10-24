defmodule ServiceRadarWebNGWeb.DeviceLive.AvailabilityBadgeTest do
  # The device list badge owns how a device's canonical availability is shown: the
  # three states, the per-agent reachability next to it and the negative-control
  # indicators (add-merged-device-availability, task 5.10).
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ServiceRadarWebNG.Devices.MergedAvailability
  alias ServiceRadarWebNGWeb.DeviceLive.IndexView.Badges

  @moduletag :db_free

  @decided_at "2026-08-30T18:00:00Z"
  @now ~U[2026-08-30 20:30:00Z]

  test "each canonical state renders its own badge" do
    for {state, label} <- [available: "Online", unavailable: "Offline", unknown: "Unknown"] do
      badge = render_badge(availability(state: Atom.to_string(state)))

      assert attribute(badge, "#badge", "data-availability-state") == Atom.to_string(state)
      assert text(badge, "[data-availability-badge]") == label
    end
  end

  test "an Unknown device is not shown as Offline even when its last boolean was false" do
    badge = render_badge(availability(state: "unknown"))

    refute text(badge, "#badge") =~ "Offline"
    assert attribute(badge, "[data-availability-badge]", "data-tip") =~ "No fresh availability evidence"
  end

  test "a device whose availability is still loading shows no state" do
    badge = render_badge(nil)

    assert text(badge, "#badge") == "—"
    assert badge |> LazyHTML.query("[data-availability-state]") |> Enum.empty?()
  end

  test "the tooltip names the deciding source, the decision time and each agent's result" do
    badge =
      render_badge(
        availability(
          state: "available",
          decided_by: %{
            "source_kind" => "wifi_map",
            "authority_class" => "managing_controller",
            "reporter_agent_id" => "agent-site01"
          },
          conflict: true,
          agent_results: [
            %{agent_id: "agent-a", agent_name: "SITE01-probe", available?: false},
            %{agent_id: "agent-b", agent_name: nil, available?: true}
          ]
        )
      )

    tip = attribute(badge, "[data-availability-badge]", "data-tip")

    assert tip =~ "Decided by wifi_map (managing_controller) via agent-site01, 2h ago"
    assert tip =~ "other evidence disagrees"
    assert tip =~ "SITE01-probe: down"
    assert tip =~ "agent-b: up"
  end

  test "a controller-decided device reached by none of its agents shows the partial marker" do
    badge =
      render_badge(availability(state: "available", agents: %{"up" => 0, "down" => 2, "total" => 2}))

    assert text(badge, "[data-availability-badge]") == "Online"
    assert attribute(badge, "[data-agent-reachability]", "data-agent-reachability") == "0/2"
    assert text(badge, "[data-agent-reachability]") =~ "up from 0 of 2 agents"
    assert attribute(badge, "[data-partial-reachability]", "data-tip") == "Unreachable from 2 agents"
  end

  test "a device every agent reaches shows N of M without the partial marker" do
    badge =
      render_badge(availability(state: "available", agents: %{"up" => 3, "down" => 0, "total" => 3}))

    assert text(badge, "[data-agent-reachability]") =~ "up from 3 of 3 agents"
    assert badge |> LazyHTML.query("[data-partial-reachability]") |> Enum.empty?()
  end

  test "negative controls show a verified block and a policy violation separately" do
    verified =
      render_badge(
        availability(
          state: "available",
          agents: %{"up" => 1, "down" => 0, "total" => 1, "blocked_verified" => 2}
        )
      )

    assert text(verified, ~s([data-negative-control="verified"])) == "blocked as expected (2)"
    assert verified |> LazyHTML.query(~s([data-negative-control="violation"])) |> Enum.empty?()

    violated =
      render_badge(
        availability(
          state: "available",
          agents: %{"up" => 1, "down" => 0, "total" => 1, "policy_violation" => 1}
        )
      )

    assert text(violated, ~s([data-negative-control="violation"])) ==
             "POLICY VIOLATION: reachable from 1 agent that should be blocked"
  end

  test "no agent summary is shown before the resolver has summarized the agents" do
    badge = render_badge(availability(state: "available", agents: nil))

    assert badge |> LazyHTML.query("[data-agent-reachability]") |> Enum.empty?()
    assert badge |> LazyHTML.query("[data-negative-control]") |> Enum.empty?()
  end

  defp availability(fields) do
    fields = Map.new(fields)

    %{
      "availability_state" => Map.fetch!(fields, :state),
      "availability_decided_by" => Map.get(fields, :decided_by),
      "availability_changed_at" => @decided_at,
      "availability_conflict" => Map.get(fields, :conflict, false),
      "availability_agents" => Map.get(fields, :agents)
    }
    |> MergedAvailability.from_columns()
    |> Map.put(:agent_results, Map.get(fields, :agent_results, []))
  end

  defp render_badge(availability) do
    (&Badges.availability_badge/1)
    |> render_component(id: "badge", availability: availability, now: @now)
    |> LazyHTML.from_fragment()
  end

  defp attribute(document, selector, name) do
    case document |> LazyHTML.query(selector) |> LazyHTML.attribute(name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp text(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end
end
