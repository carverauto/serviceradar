defmodule ServiceRadarCoreElx.CameraRelay.BoomboxBranchManagerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarCoreElx.CameraRelay.BoomboxBranchManager
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager

  defmodule ResultIngestorStub do
    @moduledoc false

    def ingest(result) do
      send(test_pid(), {:ingest_result, result})
      :ok
    end

    defp test_pid, do: Application.fetch_env!(:serviceradar_core_elx, :boombox_branch_manager_test_pid)
  end

  defmodule ResultIngestorErrorStub do
    @moduledoc false

    def ingest(_result), do: {:error, :ingest_failed}
  end

  setup do
    previous_state = :sys.get_state(BoomboxBranchManager)
    test_pid = self()
    previous_test_pid = Application.get_env(:serviceradar_core_elx, :boombox_branch_manager_test_pid)

    Application.put_env(:serviceradar_core_elx, :boombox_branch_manager_test_pid, test_pid)

    :sys.replace_state(BoomboxBranchManager, fn state ->
      state
      |> Map.put(:branches, %{})
      |> Map.put(:max_branches_per_session, 1)
      |> Map.put(:result_ingestor, ResultIngestorStub)
    end)

    on_exit(fn ->
      :telemetry.detach(telemetry_handler_id(test_pid))
      restore_env(:boombox_branch_manager_test_pid, previous_test_pid)
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

  test "ingests boombox worker results through the normal analysis result contract with provenance" do
    relay_session_id = "relay-boombox-result-1"
    branch_id = "boombox-result-1"
    output = Path.join(System.tmp_dir!(), "serviceradar-boombox-result-#{System.unique_integer([:positive])}.h264")

    attach_telemetry_handler(self(), [
      [:serviceradar, :camera_relay, :analysis, :dispatch_succeeded]
    ])

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert {:ok, _branch} =
             BoomboxBranchManager.open_branch(%{
               relay_session_id: relay_session_id,
               branch_id: branch_id,
               worker_id: "boombox-worker-1",
               camera_source_id: "camera-source-1",
               camera_device_uid: "camera-device-1",
               stream_profile_id: "profile-main",
               output: output
             })

    assert :ok =
             BoomboxBranchManager.ingest_result(relay_session_id, branch_id, %{
               "sequence" => 44,
               "detection" => %{
                 "kind" => "object_detection",
                 "label" => "person",
                 "confidence" => 0.91
               },
               "metadata" => %{"pipeline" => "boombox"}
             })

    assert_receive {:ingest_result,
                    %{
                      "schema" => "camera_analysis_result.v1",
                      "relay_session_id" => ^relay_session_id,
                      "branch_id" => ^branch_id,
                      "worker_id" => "boombox-worker-1",
                      "camera_source_id" => "camera-source-1",
                      "camera_device_uid" => "camera-device-1",
                      "stream_profile_id" => "profile-main",
                      "sequence" => 44,
                      "metadata" => %{
                        "analysis_adapter" => "boombox",
                        "pipeline" => "boombox"
                      }
                    }},
                   1_000

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :dispatch_succeeded],
                    %{result_count: 1, sequence: 44, timeout_ms: 0},
                    %{
                      relay_session_id: ^relay_session_id,
                      branch_id: ^branch_id,
                      worker_id: "boombox-worker-1",
                      adapter: "boombox"
                    }},
                   1_000

    assert :ok = BoomboxBranchManager.close_branch(relay_session_id, branch_id)
    assert :ok = PipelineManager.close_session(relay_session_id)
    File.rm(output)
  end

  test "reports boombox worker ingestion failures with preserved provenance" do
    relay_session_id = "relay-boombox-result-2"
    branch_id = "boombox-result-2"
    output = Path.join(System.tmp_dir!(), "serviceradar-boombox-result-error-#{System.unique_integer([:positive])}.h264")

    attach_telemetry_handler(self(), [
      [:serviceradar, :camera_relay, :analysis, :dispatch_failed]
    ])

    :sys.replace_state(BoomboxBranchManager, fn state ->
      Map.put(state, :result_ingestor, ResultIngestorErrorStub)
    end)

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert {:ok, _branch} =
             BoomboxBranchManager.open_branch(%{
               relay_session_id: relay_session_id,
               branch_id: branch_id,
               worker_id: "boombox-worker-2",
               output: output
             })

    assert {:error, :ingest_failed} =
             BoomboxBranchManager.ingest_result(relay_session_id, branch_id, %{
               "sequence" => 12,
               "detection" => %{"label" => "vehicle"}
             })

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :dispatch_failed],
                    %{result_count: 1, sequence: 12, timeout_ms: 0},
                    %{
                      relay_session_id: ^relay_session_id,
                      branch_id: ^branch_id,
                      worker_id: "boombox-worker-2",
                      adapter: "boombox",
                      reason: "ingest_failed"
                    }},
                   1_000

    assert :ok = BoomboxBranchManager.close_branch(relay_session_id, branch_id)
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)

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
