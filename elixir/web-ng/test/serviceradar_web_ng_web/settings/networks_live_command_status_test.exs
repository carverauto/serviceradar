defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.CommandStatusTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.CommandStatus
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Infos

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

  test "passive observers preserve a new terminal event that precedes its dispatch envelope" do
    statuses =
      CommandStatus.reduce_sweep_dispatch(
        %{},
        sweep_dispatch("dispatch-old", "10", :finished, commands: [%{agent_id: "agent-old", command_id: "command-old"}])
      )

    statuses =
      CommandStatus.reduce_sweep_member_event(statuses, {
        :result,
        member_event("group-1", "command-new", "agent-new", %{
          sweep_dispatch_id: "dispatch-new",
          sweep_dispatch_generation: "20",
          success: true,
          payload: %{hosts: 12},
          message: "new run complete"
        })
      })

    # A future run is buffered, not exposed as the currently visible run.
    assert Map.keys(statuses["group-1"].members) == ["command-old"]

    statuses =
      CommandStatus.reduce_sweep_dispatch(
        statuses,
        sweep_dispatch("dispatch-new", "20", :finished, commands: [%{agent_id: "agent-new", command_id: "command-new"}])
      )

    assert statuses["group-1"].sweep_dispatch_id == "dispatch-new"
    assert statuses["group-1"].sweep_dispatch_generation == "20"
    assert statuses["group-1"].members["command-new"].state == :success
    assert statuses["group-1"].members["command-new"].result_payload == %{hosts: 12}

    after_late_events =
      statuses
      |> CommandStatus.reduce_sweep_member_event({
        :result,
        member_event("group-1", "command-old", "agent-old", %{
          sweep_dispatch_id: "dispatch-old",
          sweep_dispatch_generation: "10",
          success: true
        })
      })
      |> CommandStatus.reduce_sweep_member_event({
        :progress,
        member_event("group-1", "command-unrelated", "agent-x", %{
          sweep_dispatch_id: "dispatch-new",
          sweep_dispatch_generation: "20",
          progress_percent: 99
        })
      })

    assert after_late_events == statuses
  end

  test "a newer started generation cannot be replaced by an older completion or envelope" do
    statuses =
      %{}
      |> CommandStatus.reduce_sweep_dispatch(sweep_dispatch("dispatch-old", "10", :started))
      |> CommandStatus.reduce_sweep_dispatch(sweep_dispatch("dispatch-new", "20", :started))
      |> CommandStatus.reduce_sweep_member_event({
        :progress,
        member_event("group-1", "command-new", "agent-new", %{
          sweep_dispatch_id: "dispatch-new",
          sweep_dispatch_generation: "20",
          progress_percent: 65
        })
      })

    after_old =
      statuses
      |> CommandStatus.reduce_sweep_member_event({
        :result,
        member_event("group-1", "command-old", "agent-old", %{
          sweep_dispatch_id: "dispatch-old",
          sweep_dispatch_generation: "10",
          success: true
        })
      })
      |> CommandStatus.reduce_sweep_dispatch(
        sweep_dispatch("dispatch-old", "10", :finished, commands: [%{agent_id: "agent-old", command_id: "command-old"}])
      )

    assert after_old == statuses

    finished =
      CommandStatus.reduce_sweep_dispatch(
        after_old,
        sweep_dispatch("dispatch-new", "20", :finished, commands: [%{agent_id: "agent-new", command_id: "command-new"}])
      )

    assert finished["group-1"].sweep_dispatch_id == "dispatch-new"
    assert finished["group-1"].members["command-new"].state == :progress
    assert finished["group-1"].members["command-new"].progress_percent == 65
    refute Map.has_key?(finished["group-1"].members, "command-old")
  end

  test "an ignored older final envelope leaves current status and flash unchanged" do
    statuses =
      CommandStatus.reduce_sweep_dispatch(
        %{},
        sweep_dispatch("dispatch-new", "20", :started)
      )

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{"info" => "current dispatch"},
        sweep_command_statuses: statuses
      },
      private: %{live_temp: %{}}
    }

    old_final =
      sweep_dispatch("dispatch-old", "10", :finished, commands: [%{agent_id: "agent-old", command_id: "command-old"}])

    assert {:noreply, updated_socket} = Infos.handle_info({:sweep_dispatch, old_final}, socket)
    assert updated_socket.assigns.sweep_command_statuses == statuses
    assert updated_socket.assigns.flash == %{"info" => "current dispatch"}
    assert updated_socket.private.live_temp == %{}
  end

  test "decimal dispatch generations compare numerically across digit widths" do
    {:accepted, old_statuses} =
      CommandStatus.apply_sweep_dispatch(
        %{},
        sweep_dispatch("dispatch-old", "9", :started)
      )

    assert {:accepted, newer_statuses} =
             CommandStatus.apply_sweep_dispatch(
               old_statuses,
               sweep_dispatch("dispatch-new", "10", :started)
             )

    assert newer_statuses["group-1"].sweep_dispatch_id == "dispatch-new"
    assert newer_statuses["group-1"].sweep_dispatch_generation == "10"
  end

  test "bounded future-event buffer keeps the newest decimal generations numerically" do
    statuses =
      CommandStatus.reduce_sweep_dispatch(
        %{},
        sweep_dispatch("dispatch-current", "1", :started)
      )

    statuses =
      Enum.reduce(["9", "10", "11", "12", "13"], statuses, fn generation, statuses ->
        CommandStatus.reduce_sweep_member_event(statuses, {
          :result,
          member_event("group-1", "command-#{generation}", "agent-#{generation}", %{
            sweep_dispatch_id: "dispatch-#{generation}",
            sweep_dispatch_generation: generation,
            success: true
          })
        })
      end)

    statuses =
      CommandStatus.reduce_sweep_dispatch(
        statuses,
        sweep_dispatch("dispatch-10", "10", :finished, commands: [%{agent_id: "agent-10", command_id: "command-10"}])
      )

    assert statuses["group-1"].members["command-10"].state == :success
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

  defp sweep_dispatch(dispatch_id, generation, phase, extra \\ []) do
    Map.merge(
      %{
        sweep_group_id: "group-1",
        sweep_dispatch_id: dispatch_id,
        sweep_dispatch_generation: generation,
        phase: phase,
        commands: [],
        failures: []
      },
      Map.new(extra)
    )
  end
end
