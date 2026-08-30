defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.CommandStatusTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.CommandStatus

  @moduletag :db_free

  test "seeds one queued member per command and keys immediate failures by agent UID" do
    statuses =
      %{}
      |> CommandStatus.begin_sweep_dispatch("group-1")
      |> CommandStatus.seed_sweep_dispatch(%{
        sweep_group_id: "group-1",
        commands: [
          %{agent_id: "agent-a", command_id: "command-a"},
          %{agent_id: "agent-b", command_id: "command-b"}
        ],
        failures: [
          %{agent_id: "agent-c", reason: {:agent_capability_missing, "agent-c", "sweep"}}
        ]
      })

    status = statuses["group-1"]

    assert status.seeded?
    assert status.members |> Map.keys() |> Enum.sort() == ["command-a", "command-b"]
    assert status.members["command-a"] == queued_member("command-a", "agent-a")
    assert status.members["command-b"] == queued_member("command-b", "agent-b")

    assert status.failures == %{
             "agent-c" => %{
               agent_id: "agent-c",
               reason: {:agent_capability_missing, "agent-c", "sweep"}
             }
           }

    assert status.summary == %{
             queued: 2,
             running: 0,
             pending: 2,
             success: 0,
             failure: 1,
             total: 3
           }
  end

  test "merges pre-seed updates and never lets one member or a late ack downgrade another" do
    statuses = CommandStatus.begin_sweep_dispatch(%{}, "group-1")

    statuses =
      CommandStatus.reduce_sweep_member_event(statuses, {
        :progress,
        member_event("group-1", "command-b", "agent-b", %{
          progress_percent: 35,
          message: "agent B running"
        })
      })

    statuses =
      CommandStatus.reduce_sweep_member_event(statuses, {
        :result,
        member_event("group-1", "command-a", "agent-a", %{
          success: true,
          payload: %{hosts: 8},
          message: "agent A complete"
        })
      })

    statuses =
      CommandStatus.seed_sweep_dispatch(statuses, %{
        sweep_group_id: "group-1",
        commands: [
          %{agent_id: "agent-a", command_id: "command-a"},
          %{agent_id: "agent-b", command_id: "command-b"}
        ],
        failures: []
      })

    assert statuses["group-1"].members["command-a"].state == :success
    assert statuses["group-1"].members["command-a"].result_payload == %{hosts: 8}
    assert statuses["group-1"].members["command-b"].state == :progress
    assert statuses["group-1"].members["command-b"].progress_percent == 35

    statuses =
      CommandStatus.reduce_sweep_member_event(statuses, {
        :ack,
        member_event("group-1", "command-a", "agent-a", %{message: "late ack"})
      })

    assert statuses["group-1"].members["command-a"].state == :success
    assert statuses["group-1"].members["command-a"].message == "agent A complete"
    assert statuses["group-1"].members["command-b"].state == :progress

    statuses =
      CommandStatus.seed_sweep_dispatch(statuses, %{
        sweep_group_id: "group-1",
        commands: [
          %{agent_id: "agent-a", command_id: "command-a"},
          %{agent_id: "agent-b", command_id: "command-b"}
        ],
        failures: []
      })

    assert statuses["group-1"].members["command-a"].state == :success
    assert statuses["group-1"].members["command-a"].message == "agent A complete"
    assert statuses["group-1"].members["command-b"].state == :progress
    assert statuses["group-1"].members["command-b"].progress_percent == 35

    assert statuses["group-1"].summary == %{
             queued: 0,
             running: 1,
             pending: 1,
             success: 1,
             failure: 0,
             total: 2
           }
  end

  test "a new dispatch replaces the prior run and rejects late or unknown command IDs" do
    first =
      CommandStatus.seed_sweep_dispatch(%{}, %{
        sweep_group_id: "group-1",
        commands: [%{agent_id: "agent-a", command_id: "old-command"}],
        failures: [%{agent_id: "agent-b", reason: {:agent_offline, "agent-b"}}]
      })

    second =
      CommandStatus.seed_sweep_dispatch(first, %{
        sweep_group_id: "group-1",
        commands: [%{agent_id: "agent-d", command_id: "new-command"}],
        failures: []
      })

    assert Map.keys(second["group-1"].members) == ["new-command"]
    assert second["group-1"].failures == %{}

    assert second ==
             CommandStatus.reduce_sweep_member_event(second, {
               :result,
               member_event("group-1", "old-command", "agent-a", %{success: true})
             })

    assert second ==
             CommandStatus.reduce_sweep_member_event(second, {
               :progress,
               member_event("group-1", "unknown-command", "agent-x", %{
                 progress_percent: 99
               })
             })
  end

  test "zero-success dispatch remains visible with stable human failure reasons" do
    statuses =
      CommandStatus.seed_sweep_dispatch(%{}, %{
        sweep_group_id: "group-1",
        commands: [],
        failures: [
          %{agent_id: "agent-a", reason: {:agent_offline, "agent-a"}},
          %{agent_id: "agent-b", reason: {:agent_partition_ambiguous, "agent-b"}}
        ],
        error: {:agent_offline, "agent-a"}
      })

    status = statuses["group-1"]

    assert status.state == :error
    assert status.summary.pending == 0
    assert status.summary.success == 0
    assert status.summary.failure == 2
    assert CommandStatus.command_status_label(status) == "0 completed, 2 failed"
    assert CommandStatus.command_status_variant(status) == "error"
    assert CommandStatus.format_sweep_failure_reason({:agent_offline, "agent-a"}) == "Agent is offline"

    assert CommandStatus.format_sweep_failure_reason({:agent_partition_ambiguous, "agent-b"}) ==
             "Multiple canonical control sessions"
  end

  test "an all-agent dispatch with no live sessions remains an explicit error" do
    statuses =
      CommandStatus.seed_sweep_dispatch(%{}, %{
        sweep_group_id: "group-1",
        commands: [],
        failures: [],
        error: :agent_offline
      })

    status = statuses["group-1"]

    assert status.state == :error

    assert status.summary == %{
             queued: 0,
             running: 0,
             pending: 0,
             success: 0,
             failure: 0,
             total: 0
           }

    assert CommandStatus.command_status_label(status) == "Dispatch failed"
    assert CommandStatus.command_status_variant(status) == "error"
  end

  test "mapper command status keeps its existing flat map shape" do
    updated_at = ~U[2026-08-30 12:00:00Z]

    assert CommandStatus.update_command_status(%{}, "mapper-job", :progress, %{
             message: "discovering",
             progress_percent: 47,
             updated_at: updated_at
           }) == %{
             "mapper-job" => %{
               state: :progress,
               message: "discovering",
               progress_percent: 47,
               updated_at: updated_at
             }
           }
  end

  defp queued_member(command_id, agent_id) do
    %{
      command_id: command_id,
      agent_id: agent_id,
      state: :sent,
      message: "Sweep command queued"
    }
  end

  defp member_event(group_id, command_id, agent_id, extra) do
    Map.merge(
      %{
        sweep_group_id: group_id,
        command_id: command_id,
        agent_id: agent_id
      },
      extra
    )
  end
end
