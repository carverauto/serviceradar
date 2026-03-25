defmodule ServiceRadarCoreElx.CameraRelay.ReferenceAnalysisWorkerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarCoreElx.CameraRelay.AnalysisBranchManager
  alias ServiceRadarCoreElx.CameraRelay.AnalysisDispatchManager
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager
  alias ServiceRadarCoreElx.CameraRelay.ReferenceAnalysisWorker

  defmodule ResultIngestorStub do
    @moduledoc false

    def ingest(result) do
      send(test_pid(), {:ingest_result, result})
      :ok
    end

    defp test_pid, do: Application.fetch_env!(:serviceradar_core_elx, :reference_analysis_worker_test_pid)
  end

  setup do
    test_pid = self()
    port = free_port()

    previous_dispatch_state = :sys.get_state(AnalysisDispatchManager)
    previous_branch_state = :sys.get_state(AnalysisBranchManager)
    previous_test_pid = Application.get_env(:serviceradar_core_elx, :reference_analysis_worker_test_pid)

    Application.put_env(:serviceradar_core_elx, :reference_analysis_worker_test_pid, test_pid)

    :sys.replace_state(AnalysisDispatchManager, fn state ->
      state
      |> Map.put(:branches, %{})
      |> Map.put(:adapter, nil)
      |> Map.put(:adapter_opts, [])
      |> Map.put(:result_ingestor, ResultIngestorStub)
    end)

    :sys.replace_state(AnalysisBranchManager, fn state ->
      state
      |> Map.put(:branches, %{})
      |> Map.put(:max_branches_per_session, 8)
      |> Map.put(:min_sample_interval_ms, 0)
      |> Map.put(:default_max_queue_len, 32)
    end)

    worker =
      start_supervised!({ReferenceAnalysisWorker, port: port, worker_id: "reference-analysis-worker"})

    on_exit(fn ->
      close_all_dispatches()
      :telemetry.detach(telemetry_handler_id(test_pid))
      restore_env(:reference_analysis_worker_test_pid, previous_test_pid)
      :sys.replace_state(AnalysisDispatchManager, fn _ -> previous_dispatch_state end)
      :sys.replace_state(AnalysisBranchManager, fn _ -> previous_branch_state end)
      stop_worker(worker)
    end)

    {:ok, port: port}
  end

  test "returns a deterministic derived result for supported keyframe input", %{port: port} do
    {:ok, response} =
      Req.post("http://127.0.0.1:#{port}/analyze",
        json: %{
          schema: "camera_analysis_input.v1",
          relay_session_id: "relay-1",
          branch_id: "branch-1",
          media_ingest_id: "core-media-1",
          sequence: 7,
          codec: "h264",
          payload_format: "annexb",
          keyframe: true,
          payload: Base.encode64(<<1, 2, 3>>)
        },
        retry: false
      )

    assert response.status == 200
    assert is_list(response.body)

    assert [
             %{
               "schema" => "camera_analysis_result.v1",
               "worker_id" => "reference-analysis-worker",
               "detection" => detection
             }
           ] = response.body

    assert detection["kind"] == "reference_keyframe_detection"
    assert detection["label"] == "h264_annexb_keyframe"
  end

  test "dispatches through the HTTP adapter and ingests derived results with provenance", %{port: port} do
    relay_session_id = "relay-reference-worker-1"
    branch_id = "reference-http-1"

    attach_telemetry_handler(self(), [
      [:serviceradar, :camera_relay, :analysis, :dispatch_succeeded]
    ])

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert {:ok, _branch} =
             AnalysisDispatchManager.open_http_branch(%{
               relay_session_id: relay_session_id,
               branch_id: branch_id,
               worker_id: "reference-analysis-worker",
               endpoint_url: "http://127.0.0.1:#{port}/analyze",
               policy: %{sample_interval_ms: 0},
               max_in_flight: 1
             })

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-analysis-reference",
               sequence: 9,
               pts: 0,
               dts: 0,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: true,
               payload: <<0, 0, 0, 1, 103, 100, 0, 31>>
             })

    assert_receive {:ingest_result,
                    %{
                      "relay_session_id" => ^relay_session_id,
                      "branch_id" => ^branch_id,
                      "worker_id" => "reference-analysis-worker",
                      "media_ingest_id" => "core-media-analysis-reference",
                      "sequence" => 9,
                      "detection" => %{"label" => "h264_annexb_keyframe"}
                    }},
                   1_500

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :dispatch_succeeded], %{sequence: 9},
                    %{relay_session_id: ^relay_session_id, branch_id: ^branch_id, worker_id: "reference-analysis-worker"}},
                   1_000

    assert :ok = AnalysisDispatchManager.close_http_branch(relay_session_id, branch_id)
    assert :ok = PipelineManager.close_session(relay_session_id)
  end

  test "returns a bounded no-op for non-keyframe input and does not ingest a derived event", %{port: port} do
    relay_session_id = "relay-reference-worker-2"
    branch_id = "reference-http-2"

    attach_telemetry_handler(self(), [
      [:serviceradar, :camera_relay, :analysis, :dispatch_succeeded]
    ])

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert {:ok, _branch} =
             AnalysisDispatchManager.open_http_branch(%{
               relay_session_id: relay_session_id,
               branch_id: branch_id,
               worker_id: "reference-analysis-worker",
               endpoint_url: "http://127.0.0.1:#{port}/analyze",
               policy: %{sample_interval_ms: 0},
               max_in_flight: 1
             })

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-analysis-reference",
               sequence: 10,
               pts: 0,
               dts: 0,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: false,
               payload: <<0, 0, 0, 1, 101, 1, 2, 3>>
             })

    refute_receive {:ingest_result, _result}, 500

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :dispatch_succeeded], %{sequence: 10},
                    %{relay_session_id: ^relay_session_id, branch_id: ^branch_id, worker_id: "reference-analysis-worker"}},
                   1_000

    assert :ok = AnalysisDispatchManager.close_http_branch(relay_session_id, branch_id)
    assert :ok = PipelineManager.close_session(relay_session_id)
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

  defp telemetry_handler_id(test_pid), do: "reference-analysis-worker-test-#{inspect(test_pid)}"

  defp close_all_dispatches do
    state = :sys.get_state(AnalysisDispatchManager)

    Enum.each(state.branches, fn {relay_session_id, branches} ->
      Enum.each(Map.keys(branches), fn branch_id ->
        _ = AnalysisDispatchManager.close_http_branch(relay_session_id, branch_id)
      end)
    end)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)

  defp stop_worker(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end
end
