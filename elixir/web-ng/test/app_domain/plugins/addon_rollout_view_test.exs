defmodule ServiceRadarWebNG.Plugins.AddonRolloutViewTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Plugins.AddonRolloutView

  @moduletag :db_free

  test "assignment rollouts name the agent, not the assignment UUID" do
    assignment_id = "11111111-1111-1111-1111-111111111111"
    agent_uid = "farm01-edge-03"

    view =
      AddonRolloutView.present(
        %{
          id: "rollout-1",
          addon_id: "scalibr-endpoint-inventory",
          source_type: :assignment,
          source_id: assignment_id,
          trigger: :track_latest,
          state: :paused,
          blocked_reason: "candidate_health_timeout",
          previous_package: %{name: "SCALIBR", version: "0.1.3"},
          candidate_package: %{name: "SCALIBR", version: "0.1.4"},
          targets: [
            %{
              agent_uid: agent_uid,
              batch_index: 0,
              classification: :eligible,
              state: :rolled_back,
              reason_code: "candidate_health_timeout"
            }
          ]
        },
        %{
          assignments: %{assignment_id => %{agent_uid: agent_uid}},
          agents: %{
            agent_uid => %{uid: agent_uid, name: "farm01-edge-03", host: "10.0.0.12"}
          }
        }
      )

    assert view.scope_kind == :agent
    assert view.scope_label == "farm01-edge-03"
    assert view.scope_caption == "Direct assignment · farm01-edge-03"
    assert view.scope_href == "/agents/farm01-edge-03"
    refute view.scope_label =~ assignment_id
    refute view.summary =~ assignment_id
    assert view.state_label == "Paused"
    assert view.summary =~ "farm01-edge-03 never reported healthy on 0.1.4"
    assert view.summary =~ "rolled that agent back to 0.1.3"
    assert view.progress_label == "0 of 1 agent on 0.1.4 · 1 held on 0.1.3"
    assert hd(view.targets).batch_label == "Canary"
    assert hd(view.targets).state_label == "Rolled back"
  end

  test "profile rollouts name the profile and count agents" do
    profile_id = "22222222-2222-2222-2222-222222222222"

    view =
      AddonRolloutView.present(
        %{
          id: "rollout-2",
          addon_id: "anomaly",
          source_type: :profile,
          source_id: profile_id,
          trigger: :track_latest,
          state: :paused,
          blocked_reason: "candidate_reported_unhealthy",
          previous_package: %{name: "Anomaly Detector", version: "0.3.2"},
          candidate_package: %{name: "Anomaly Detector", version: "0.3.3"},
          targets: [
            %{
              agent_uid: "agent-a",
              batch_index: 0,
              classification: :eligible,
              state: :rolled_back,
              reason_code: "candidate_reported_unhealthy"
            },
            %{
              agent_uid: "agent-b",
              batch_index: 1,
              classification: :eligible,
              state: :pending
            }
          ]
        },
        %{
          profiles: %{profile_id => %{name: "Linux canaries"}},
          agents: %{
            "agent-a" => %{uid: "agent-a", name: "canary-1"},
            "agent-b" => %{uid: "agent-b", name: "canary-2"}
          }
        }
      )

    assert view.scope_kind == :profile
    assert view.scope_label == "Linux canaries"
    assert view.scope_caption == "Add-on profile · 2 agents"
    refute view.summary =~ profile_id
    assert view.summary =~ "canary-1 reported 0.3.3 as unhealthy"
    assert view.summary =~ "rest of the profile stays on the last good version"
    assert view.addon_name == "Anomaly Detector"
  end

  test "fleet health tells the operator what to do for a blocked canary" do
    health =
      AddonRolloutView.fleet_health(%{
        category: :action_required,
        reason_code: "candidate_reported_unhealthy",
        assigned_version: "0.3.1",
        running_version: "0.3.0",
        rollout_candidate_version: "0.3.1",
        rollout_id: "rollout-1"
      })

    assert health.title == "Update blocked"
    assert health.action == :review_rollout
    assert health.detail =~ "0.3.1 reported unhealthy"
    assert health.detail =~ "This agent is running 0.3.0"
    assert health.detail =~ "Cancel or resume"
  end

  test "fleet health for a timed-out update keeps the running version in the sentence" do
    health =
      AddonRolloutView.fleet_health(%{
        category: :action_required,
        reason_code: "candidate_health_timeout",
        assigned_version: "0.1.2",
        running_version: "0.1.2",
        latest_approved_version: "0.1.3",
        rollout_candidate_version: "0.1.3"
      })

    assert health.title == "Update blocked"
    assert health.detail =~ "0.1.3 did not pass health"
    assert health.detail =~ "running 0.1.2"
  end

  test "a finished failed rollout is not an open job" do
    view =
      AddonRolloutView.present(%{
        addon_id: "bumblebee",
        source_type: :profile,
        state: :failed,
        blocked_reason: "candidate_health_timeout",
        previous_package: %{version: "0.1.3"},
        candidate_package: %{version: "0.1.4"},
        targets: []
      })

    refute view.active?
    refute view.attention?
    assert view.summary =~ "That attempt stopped"
    refute view.summary =~ "paused so"
  end

  test "operator pause without a blocked reason is explained" do
    view =
      AddonRolloutView.present(%{
        addon_id: "netprobe",
        source_type: :assignment,
        source_id: "33333333-3333-3333-3333-333333333333",
        state: :paused,
        previous_package: %{version: "0.2.1"},
        candidate_package: %{version: "0.2.2"},
        targets: []
      })

    assert view.summary =~ "An operator paused this rollout"
    assert view.scope_label == "Unknown agent"
  end
end
