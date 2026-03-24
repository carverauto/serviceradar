defmodule ServiceRadarCoreElx.CameraRelay.AnalysisDispatchManagerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarCoreElx.CameraRelay.AnalysisBranchManager
  alias ServiceRadarCoreElx.CameraRelay.AnalysisDispatchManager
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager

  defmodule AdapterStub do
    @moduledoc false
    def deliver(input, worker, opts) do
      send(opts[:test_pid], {:deliver, input, worker})

      case opts[:mode] do
        :success ->
          {:ok, [%{"detection" => %{"kind" => "object_detection", "label" => "person", "confidence" => 0.9}}]}

        :timeout ->
          {:error, :timeout}

        :http_error ->
          {:error, {:http_status, 503, %{"error" => "down"}}}

        {:sleep_success, ms} ->
          Process.sleep(ms)
          {:ok, [%{"detection" => %{"kind" => "object_detection", "label" => "person", "confidence" => 0.9}}]}
      end
    end
  end

  defmodule ResultIngestorStub do
    @moduledoc false
    def ingest(result) do
      send(test_pid(), {:ingest_result, result})

      case mode() do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp mode, do: Application.get_env(:serviceradar_core_elx, :analysis_dispatch_result_ingestor_mode, :ok)
    defp test_pid, do: Application.fetch_env!(:serviceradar_core_elx, :analysis_dispatch_test_pid)
  end

  setup do
    test_pid = self()

    previous_dispatch_state = :sys.get_state(AnalysisDispatchManager)
    previous_branch_state = :sys.get_state(AnalysisBranchManager)
    previous_test_pid = Application.get_env(:serviceradar_core_elx, :analysis_dispatch_test_pid)
    previous_ingestor_mode = Application.get_env(:serviceradar_core_elx, :analysis_dispatch_result_ingestor_mode)

    Application.put_env(:serviceradar_core_elx, :analysis_dispatch_test_pid, test_pid)
    Application.put_env(:serviceradar_core_elx, :analysis_dispatch_result_ingestor_mode, :ok)

    :sys.replace_state(AnalysisDispatchManager, fn state ->
      state
      |> Map.put(:branches, %{})
      |> Map.put(:adapter, AdapterStub)
      |> Map.put(:adapter_opts, test_pid: test_pid, mode: :success)
      |> Map.put(:result_ingestor, ResultIngestorStub)
    end)

    :sys.replace_state(AnalysisBranchManager, fn state ->
      state
      |> Map.put(:branches, %{})
      |> Map.put(:max_branches_per_session, 8)
      |> Map.put(:min_sample_interval_ms, 0)
      |> Map.put(:default_max_queue_len, 32)
    end)

    on_exit(fn ->
      close_all_dispatches()
      :telemetry.detach(telemetry_handler_id(test_pid))
      restore_env(:analysis_dispatch_test_pid, previous_test_pid)
      restore_env(:analysis_dispatch_result_ingestor_mode, previous_ingestor_mode)
      :sys.replace_state(AnalysisDispatchManager, fn _ -> previous_dispatch_state end)
      :sys.replace_state(AnalysisBranchManager, fn _ -> previous_branch_state end)
    end)

    :ok
  end

  test "dispatches analysis inputs to an HTTP worker and ingests successful results" do
    relay_session_id = "relay-analysis-dispatch-1"
    branch_id = "analysis-http-1"

    attach_telemetry_handler(self(), [
      [:serviceradar, :camera_relay, :analysis, :dispatch_succeeded]
    ])

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert {:ok, branch} =
             AnalysisDispatchManager.open_http_branch(%{
               relay_session_id: relay_session_id,
               branch_id: branch_id,
               worker_id: "worker-1",
               endpoint_url: "http://worker.local/analyze",
               policy: %{sample_interval_ms: 0},
               max_in_flight: 1
             })

    assert branch.relay_session_id == relay_session_id

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-analysis-dispatch",
               sequence: 7,
               pts: 0,
               dts: 0,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: true,
               payload: <<0, 0, 0, 1, 103, 100, 0, 31>>
             })

    assert_receive {:deliver,
                    %{
                      relay_session_id: ^relay_session_id,
                      branch_id: ^branch_id,
                      sequence: 7,
                      schema: "camera_analysis_input.v1"
                    }, %{worker_id: "worker-1", endpoint_url: "http://worker.local/analyze"}},
                   1_000

    assert_receive {:ingest_result,
                    %{
                      "relay_session_id" => ^relay_session_id,
                      "branch_id" => ^branch_id,
                      "worker_id" => "worker-1",
                      "media_ingest_id" => "core-media-analysis-dispatch",
                      "sequence" => 7
                    }},
                   1_000

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :dispatch_succeeded],
                    %{inflight_count: 0, sequence: 7},
                    %{relay_session_id: ^relay_session_id, branch_id: ^branch_id, worker_id: "worker-1"}},
                   1_000

    assert :ok = AnalysisDispatchManager.close_http_branch(relay_session_id, branch_id)
    assert :ok = PipelineManager.close_session(relay_session_id)
  end

  test "drops work when max_in_flight is exceeded and emits drop telemetry" do
    relay_session_id = "relay-analysis-dispatch-2"
    branch_id = "analysis-http-2"
    test_pid = self()

    :sys.replace_state(AnalysisDispatchManager, fn state ->
      Map.put(state, :adapter_opts, test_pid: test_pid, mode: {:sleep_success, 150})
    end)

    attach_telemetry_handler(self(), [
      [:serviceradar, :camera_relay, :analysis, :dispatch_dropped]
    ])

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert {:ok, _branch} =
             AnalysisDispatchManager.open_http_branch(%{
               relay_session_id: relay_session_id,
               branch_id: branch_id,
               worker_id: "worker-2",
               endpoint_url: "http://worker.local/analyze",
               policy: %{sample_interval_ms: 0},
               max_in_flight: 1
             })

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-analysis-dispatch",
               sequence: 1,
               pts: 0,
               dts: 0,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: true,
               payload: <<0, 0, 0, 1, 103, 100, 0, 31>>
             })

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-analysis-dispatch",
               sequence: 2,
               pts: 1_000_000,
               dts: 1_000_000,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: false,
               payload: <<0, 0, 0, 1, 101, 1, 2, 3>>
             })

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :dispatch_dropped],
                    %{inflight_count: 1, sequence: 2},
                    %{
                      relay_session_id: ^relay_session_id,
                      branch_id: ^branch_id,
                      worker_id: "worker-2",
                      reason: "max_in_flight"
                    }},
                   1_000

    assert :ok = AnalysisDispatchManager.close_http_branch(relay_session_id, branch_id)
    assert :ok = PipelineManager.close_session(relay_session_id)
  end

  test "emits timeout and failure paths without crashing relay ingest" do
    relay_session_id = "relay-analysis-dispatch-3"
    branch_id = "analysis-http-3"
    test_pid = self()

    attach_telemetry_handler(self(), [
      [:serviceradar, :camera_relay, :analysis, :dispatch_timed_out],
      [:serviceradar, :camera_relay, :analysis, :dispatch_failed]
    ])

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    :sys.replace_state(AnalysisDispatchManager, fn state ->
      Map.put(state, :adapter_opts, test_pid: test_pid, mode: :timeout)
    end)

    assert {:ok, _branch} =
             AnalysisDispatchManager.open_http_branch(%{
               relay_session_id: relay_session_id,
               branch_id: branch_id,
               worker_id: "worker-3",
               endpoint_url: "http://worker.local/analyze",
               policy: %{sample_interval_ms: 0},
               max_in_flight: 1
             })

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-analysis-dispatch",
               sequence: 3,
               pts: 0,
               dts: 0,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: true,
               payload: <<0, 0, 0, 1, 103, 100, 0, 31>>
             })

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :dispatch_timed_out], %{sequence: 3},
                    %{relay_session_id: ^relay_session_id, branch_id: ^branch_id, worker_id: "worker-3"}},
                   1_000

    assert :ok = AnalysisDispatchManager.close_http_branch(relay_session_id, branch_id)

    :sys.replace_state(AnalysisDispatchManager, fn state ->
      state
      |> Map.put(:adapter_opts, test_pid: test_pid, mode: :http_error)
      |> Map.put(:branches, %{})
    end)

    assert {:ok, _branch} =
             AnalysisDispatchManager.open_http_branch(%{
               relay_session_id: relay_session_id,
               branch_id: branch_id,
               worker_id: "worker-3",
               endpoint_url: "http://worker.local/analyze",
               policy: %{sample_interval_ms: 0},
               max_in_flight: 1
             })

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-analysis-dispatch",
               sequence: 4,
               pts: 1_000_000,
               dts: 1_000_000,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: false,
               payload: <<0, 0, 0, 1, 101, 1, 2, 3>>
             })

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :dispatch_failed], %{sequence: 4},
                    %{
                      relay_session_id: ^relay_session_id,
                      branch_id: ^branch_id,
                      worker_id: "worker-3",
                      reason: "http_status_503"
                    }},
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

  defp telemetry_handler_id(test_pid), do: "analysis-dispatch-test-#{inspect(test_pid)}"

  defp close_all_dispatches do
    state = :sys.get_state(AnalysisDispatchManager)

    Enum.each(state.branches, fn {relay_session_id, branches} ->
      Enum.each(Map.keys(branches), fn branch_id ->
        _ = AnalysisDispatchManager.close_http_branch(relay_session_id, branch_id)
      end)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
end
