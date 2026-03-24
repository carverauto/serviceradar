defmodule ServiceRadarCoreElx.CameraRelay.BoomboxBranchManagerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarCoreElx.CameraRelay.BoomboxBranchManager
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager

  setup do
    previous_state = :sys.get_state(BoomboxBranchManager)
    test_pid = self()

    :sys.replace_state(BoomboxBranchManager, fn state ->
      state
      |> Map.put(:branches, %{})
      |> Map.put(:max_branches_per_session, 1)
    end)

    on_exit(fn ->
      :telemetry.detach(telemetry_handler_id(test_pid))
      :sys.replace_state(BoomboxBranchManager, fn _ -> previous_state end)
    end)

    :ok
  end

  test "opens and closes a relay-scoped boombox branch" do
    relay_session_id = "relay-boombox-1"
    branch_id = "boombox-branch-1"
    output = Path.join(System.tmp_dir!(), "serviceradar-boombox-open-close-#{System.unique_integer([:positive])}.h264")

    attach_telemetry_handler(self(), [
      [:serviceradar, :camera_relay, :analysis, :branch_opened],
      [:serviceradar, :camera_relay, :analysis, :branch_closed],
      [:serviceradar, :camera_relay, :analysis, :branch_count_changed]
    ])

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert {:ok, branch} =
             BoomboxBranchManager.open_branch(%{
               relay_session_id: relay_session_id,
               branch_id: branch_id,
               output: output
             })

    assert branch.output == output
    assert [%{branch_id: ^branch_id}] = BoomboxBranchManager.list_branches(relay_session_id)

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :branch_opened], _,
                    %{relay_session_id: ^relay_session_id, branch_id: ^branch_id, adapter: "boombox"}}

    assert :ok = BoomboxBranchManager.close_branch(relay_session_id, branch_id)
    assert [] = BoomboxBranchManager.list_branches(relay_session_id)

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :branch_closed], _,
                    %{
                      relay_session_id: ^relay_session_id,
                      branch_id: ^branch_id,
                      adapter: "boombox",
                      reason: "requested_close"
                    }}

    assert :ok = PipelineManager.close_session(relay_session_id)
    File.rm(output)
  end

  test "enforces per-relay boombox branch limits" do
    relay_session_id = "relay-boombox-limit-1"
    output_a = Path.join(System.tmp_dir!(), "serviceradar-boombox-limit-a-#{System.unique_integer([:positive])}.h264")
    output_b = Path.join(System.tmp_dir!(), "serviceradar-boombox-limit-b-#{System.unique_integer([:positive])}.h264")

    attach_telemetry_handler(self(), [
      [:serviceradar, :camera_relay, :analysis, :limit_rejected]
    ])

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert {:ok, _branch} =
             BoomboxBranchManager.open_branch(%{
               relay_session_id: relay_session_id,
               branch_id: "boombox-branch-a",
               output: output_a
             })

    assert {:error, :limit_reached} =
             BoomboxBranchManager.open_branch(%{
               relay_session_id: relay_session_id,
               branch_id: "boombox-branch-b",
               output: output_b
             })

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :limit_rejected], %{branch_count: 1},
                    %{
                      relay_session_id: ^relay_session_id,
                      branch_id: "boombox-branch-b",
                      adapter: "boombox",
                      limit: "max_boombox_branches_per_session"
                    }}

    assert :ok = BoomboxBranchManager.close_branch(relay_session_id, "boombox-branch-a")
    assert :ok = PipelineManager.close_session(relay_session_id)
    File.rm(output_a)
    File.rm(output_b)
  end

  defp attach_telemetry_handler(test_pid, events) do
    :telemetry.detach(telemetry_handler_id(test_pid))

    :telemetry.attach_many(
      telemetry_handler_id(test_pid),
      events,
      fn event, measurements, metadata, pid ->
        send(pid, {:telemetry_event, event, measurements, metadata})
      end,
      test_pid
    )
  end

  defp telemetry_handler_id(test_pid), do: "boombox-branch-test-#{inspect(test_pid)}"
end
