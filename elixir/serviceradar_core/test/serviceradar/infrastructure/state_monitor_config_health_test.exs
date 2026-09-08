defmodule ServiceRadar.Infrastructure.StateMonitorConfigHealthTest do
  @moduledoc """
  Pure unit tests for config-wedge detection (`StateMonitor.config_wedge_reason/2`):

  - rule 1 (ack drift): a still-OUTSTANDING pushed config version left unacknowledged
    past the window marks the agent config-wedged; a quiet fleet (pushed == acked, or
    nothing pushed) never does, and neither does an agent that acked *after* the push
    (it skipped past a stale push snapshot by converging on a newer version via poll).
  - rule 2 (permanent section): a permanently failing section from the last
    sectioned ack marks the agent config-wedged regardless of ack recency.
  - acks without section statuses (legacy agents) are whole-version acks: they never
    produce a section wedge.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.StateMonitor

  @threshold ~U[2026-07-04 12:00:00Z]

  defp agent(overrides) do
    defaults = %{
      uid: "agent-1",
      config_health: :unknown,
      acked_config_version: nil,
      config_acked_at: nil,
      config_section_statuses: [],
      pushed_config_version: nil,
      config_pushed_at: nil
    }

    struct(Agent, Map.merge(defaults, Map.new(overrides)))
  end

  defp before_threshold, do: DateTime.add(@threshold, -60, :second)
  defp after_threshold, do: DateTime.add(@threshold, 60, :second)
  # Older than `before_threshold/0` — used for an ack that precedes a later push.
  defp well_before_threshold, do: DateTime.add(@threshold, -120, :second)

  describe "no-ack window (rule 1)" do
    test "no config data at all is not wedged" do
      assert StateMonitor.config_wedge_reason(agent([]), @threshold) == nil
    end

    test "pushed version acked is not wedged, however old the push" do
      healthy =
        agent(
          pushed_config_version: "v2",
          config_pushed_at: before_threshold(),
          acked_config_version: "v2",
          config_acked_at: before_threshold()
        )

      assert StateMonitor.config_wedge_reason(healthy, @threshold) == nil
    end

    test "recently pushed unacked version is not yet wedged" do
      pending =
        agent(
          pushed_config_version: "v2",
          config_pushed_at: after_threshold(),
          acked_config_version: "v1"
        )

      assert StateMonitor.config_wedge_reason(pending, @threshold) == nil
    end

    test "pushed version unacked past the window is wedged with last-acked context" do
      # Agent committed v1, then v2 was pushed (later) and never acked: the last ack
      # predates the push, so the push is still outstanding.
      wedged =
        agent(
          pushed_config_version: "v2",
          config_pushed_at: before_threshold(),
          acked_config_version: "v1",
          config_acked_at: well_before_threshold()
        )

      assert {:config_ack_timeout, metadata} =
               StateMonitor.config_wedge_reason(wedged, @threshold)

      assert metadata.pushed_config_version == "v2"
      assert metadata.acked_config_version == "v1"
      assert metadata.pushed_at == before_threshold()
    end

    test "agent that never acked any version is wedged once a push ages out" do
      never_acked =
        agent(
          pushed_config_version: "v1",
          config_pushed_at: before_threshold()
        )

      assert {:config_ack_timeout, metadata} =
               StateMonitor.config_wedge_reason(never_acked, @threshold)

      assert metadata.acked_config_version == nil
    end

    test "an ack at or after the push is not wedged (agent skipped past a stale push)" do
      # A proactive-push snapshot (v2, aged out) the agent skipped past by converging
      # on a newer version (v3) via the poll path. `pushed != acked` forever, but the
      # ack is newer than the push, so the pushed version is obsolete — not wedged.
      # Reproduces the live demo false-positive (agent runs exactly what core
      # generates, yet `pushed_config_version` froze on an older control-stream push).
      skipped_push =
        agent(
          config_health: :unhealthy,
          pushed_config_version: "v2",
          config_pushed_at: before_threshold(),
          acked_config_version: "v3",
          config_acked_at: after_threshold()
        )

      assert StateMonitor.config_wedge_reason(skipped_push, @threshold) == nil
    end

    test "an ack exactly at the push timestamp is treated as not outstanding" do
      boundary =
        agent(
          pushed_config_version: "v2",
          config_pushed_at: before_threshold(),
          acked_config_version: "v3",
          config_acked_at: before_threshold()
        )

      assert StateMonitor.config_wedge_reason(boundary, @threshold) == nil
    end
  end

  describe "permanent section failures (rule 2)" do
    test "a permanently failing section wedges even with a fresh ack" do
      wedged =
        agent(
          acked_config_version: "v2",
          config_acked_at: after_threshold(),
          pushed_config_version: "v2",
          config_pushed_at: after_threshold(),
          config_section_statuses: [
            %{
              "section" => "bumblebee",
              "disposition" => "success",
              "error" => "",
              "since" => nil
            },
            %{
              "section" => "visibility",
              "disposition" => "permanent_failure",
              "error" =>
                "merge netprobe add-on config: json: cannot unmarshal string into Go struct field " <>
                  "addonConfig.capture_interfaces of type []string",
              "since" => "2026-07-01T00:44:00Z"
            }
          ]
        )

      assert {:config_section_permanent_failure, metadata} =
               StateMonitor.config_wedge_reason(wedged, @threshold)

      assert metadata.section == "visibility"
      assert metadata.error =~ "capture_interfaces"
      assert metadata.failing_since == "2026-07-01T00:44:00Z"
    end

    test "success-only sections do not wedge" do
      healthy =
        agent(
          acked_config_version: "v2",
          pushed_config_version: "v2",
          config_pushed_at: after_threshold(),
          config_section_statuses: [
            %{"section" => "addons", "disposition" => "success", "error" => "", "since" => nil}
          ]
        )

      assert StateMonitor.config_wedge_reason(healthy, @threshold) == nil
    end

    test "legacy whole-version acks (no section statuses) never section-wedge" do
      legacy =
        agent(
          acked_config_version: "v2",
          pushed_config_version: "v2",
          config_pushed_at: before_threshold(),
          config_section_statuses: []
        )

      assert StateMonitor.config_wedge_reason(legacy, @threshold) == nil
    end

    test "atom-keyed section maps are also understood" do
      wedged =
        agent(
          config_section_statuses: [
            %{section: "endpoint_inventory", disposition: "permanent_failure", error: "boom"}
          ]
        )

      assert {:config_section_permanent_failure, metadata} =
               StateMonitor.config_wedge_reason(wedged, @threshold)

      assert metadata.section == "endpoint_inventory"
      assert metadata.error == "boom"
    end
  end
end
