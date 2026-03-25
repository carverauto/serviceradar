defmodule ServiceRadarCoreElx.CameraRelay.BoomboxSidecarManagerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarCoreElx.CameraRelay.AnalysisBranchManager
  alias ServiceRadarCoreElx.CameraRelay.BoomboxSidecarManager
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager

  defmodule ResultIngestorStub do
    @moduledoc false

    def ingest(result) do
      send(test_pid(), {:ingest_result, result})
      :ok
    end

    defp test_pid, do: Application.fetch_env!(:serviceradar_core_elx, :boombox_sidecar_test_pid)
  end

  setup do
    test_pid = self()

    previous_sidecar_state = :sys.get_state(BoomboxSidecarManager)
    previous_analysis_state = :sys.get_state(AnalysisBranchManager)
    previous_test_pid = Application.get_env(:serviceradar_core_elx, :boombox_sidecar_test_pid)

    Application.put_env(:serviceradar_core_elx, :boombox_sidecar_test_pid, test_pid)

    :sys.replace_state(BoomboxSidecarManager, fn state ->
      state
      |> Map.put(:branches, %{})
      |> Map.put(:result_ingestor, ResultIngestorStub)
    end)

    :sys.replace_state(AnalysisBranchManager, fn state ->
      state
      |> Map.put(:branches, %{})
      |> Map.put(:max_branches_per_session, 4)
      |> Map.put(:min_sample_interval_ms, 0)
      |> Map.put(:default_max_queue_len, 4)
    end)

    on_exit(fn ->
      close_all_sidecars()
      restore_env(:boombox_sidecar_test_pid, previous_test_pid)
      :sys.replace_state(BoomboxSidecarManager, fn _ -> previous_sidecar_state end)
      :sys.replace_state(AnalysisBranchManager, fn _ -> previous_analysis_state end)
    end)

    :ok
  end

  test "captures relay media through a boombox branch and ingests a deterministic result on close" do
    relay_session_id = "relay-boombox-sidecar-1"
    branch_id = "boombox-sidecar-1"
    output_path = tmp_capture_path("manual")

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert {:ok, branch} =
             BoomboxSidecarManager.open_sidecar(%{
               relay_session_id: relay_session_id,
               branch_id: branch_id,
               worker_id: "boombox-sidecar-worker-1",
               camera_source_id: "camera-source-1",
               camera_device_uid: "camera-device-1",
               stream_profile_id: "profile-main",
               output_path: output_path,
               capture_ms: 10_000
             })

    assert branch.worker_id == "boombox-sidecar-worker-1"

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-boombox-sidecar",
               sequence: 1,
               pts: 0,
               dts: 0,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: true,
               payload: keyframe_payload()
             })

    assert eventually(
             fn ->
               case File.stat(output_path) do
                 {:ok, %File.Stat{size: size}} when size > 0 -> true
                 _ -> false
               end
             end,
             40
           )

    assert :ok = BoomboxSidecarManager.close_sidecar(relay_session_id, branch_id)

    assert_receive {:ingest_result,
                    %{
                      "schema" => "camera_analysis_result.v1",
                      "relay_session_id" => ^relay_session_id,
                      "branch_id" => ^branch_id,
                      "worker_id" => "boombox-sidecar-worker-1",
                      "camera_source_id" => "camera-source-1",
                      "camera_device_uid" => "camera-device-1",
                      "stream_profile_id" => "profile-main",
                      "metadata" => %{
                        "analysis_adapter" => "boombox",
                        "analysis_mode" => "boombox_sidecar",
                        "close_reason" => "requested_close"
                      },
                      "detection" => %{
                        "kind" => "boombox_capture_summary",
                        "label" => "h264_annexb_capture"
                      }
                    }},
                   2_000

    assert [] = BoomboxSidecarManager.list_sidecars(relay_session_id)
    assert [] = AnalysisBranchManager.list_branches(relay_session_id)
    refute File.exists?(output_path)
    assert :ok = PipelineManager.close_session(relay_session_id)
  end

  test "auto-closes the sidecar on timeout and tears down the boombox branch" do
    relay_session_id = "relay-boombox-sidecar-2"
    branch_id = "boombox-sidecar-2"
    output_path = tmp_capture_path("timeout")

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert {:ok, _branch} =
             BoomboxSidecarManager.open_sidecar(%{
               relay_session_id: relay_session_id,
               branch_id: branch_id,
               worker_id: "boombox-sidecar-worker-2",
               output_path: output_path,
               capture_ms: 750
             })

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-boombox-sidecar",
               sequence: 2,
               pts: 0,
               dts: 0,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: true,
               payload: keyframe_payload()
             })

    assert_receive {:ingest_result,
                    %{
                      "relay_session_id" => ^relay_session_id,
                      "branch_id" => ^branch_id,
                      "worker_id" => "boombox-sidecar-worker-2",
                      "metadata" => %{"close_reason" => "capture_timeout"}
                    }},
                   2_000

    assert eventually(fn ->
             BoomboxSidecarManager.list_sidecars(relay_session_id) == [] and
               AnalysisBranchManager.list_branches(relay_session_id) == [] and
               not File.exists?(output_path)
           end)

    assert :ok = PipelineManager.close_session(relay_session_id)
  end

  defp close_all_sidecars do
    state = :sys.get_state(BoomboxSidecarManager)

    Enum.each(state.branches, fn {relay_session_id, branches} ->
      Enum.each(Map.keys(branches), fn branch_id ->
        _ = BoomboxSidecarManager.close_sidecar(relay_session_id, branch_id)
      end)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)

  defp eventually(fun, attempts_left \\ 20)

  defp eventually(fun, attempts_left) when attempts_left > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts_left - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp tmp_capture_path(label) do
    Path.join(System.tmp_dir!(), "serviceradar-boombox-sidecar-#{label}-#{System.unique_integer([:positive])}.h264")
  end

  defp keyframe_payload do
    """
    AAAAAWdCwArclsBEAAADAAQAAAMACjxIngAAAAFozg/IAAABBgX//03cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBI
    LjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczog
    Y2FiYWM9MCByZWY9MSBkZWJsb2NrPTA6MDowIGFuYWx5c2U9MDowIG1lPWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAg
    bWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zm
    c2V0PTAgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9j
    b21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTEga2V5aW50X21pbj0xIHNjZW5lY3V0PTAgaW50cmFfcmVm
    cmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0wAIAA
    AAFliIQ6JigACQLJ114=
    """
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end
end
