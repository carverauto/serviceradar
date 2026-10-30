defmodule ServiceRadarAgentGateway.TestSupport.EdgeRecordPublisherStub do
  @moduledoc false

  # The ingest server no longer calls a publisher: it offers to a `PublishPipeline`, whose WORKERS
  # call the publisher. A worker is neither the stream process nor the test process, so results
  # cannot travel through the process dictionary and notifications have to name the test pid.

  alias ServiceRadar.Edge.PublishPipeline

  @durable {:ok, %{stream: "TELEMETRY_EDGE_RECORD_V1_BULK", seq: 1, duplicate: false}}

  @doc "A publisher that reports each publication to `test_pid` and returns `result`."
  def publisher(test_pid, result \\ @durable) do
    fn publication, _opts ->
      send(test_pid, {:edge_record_published, publication})
      result
    end
  end

  @doc """
  Starts a bulk-class `PublishPipeline` over `publisher` under the test supervisor and routes the
  ingest server to it. Call from the test process.
  """
  def start_pipeline!(publisher, opts \\ []) do
    tasks = ExUnit.Callbacks.start_supervised!({Task.Supervisor, []}, id: make_ref())

    pipeline =
      ExUnit.Callbacks.start_supervised!(
        {
          PublishPipeline,
          # No pool: these publishers never admit, so the window they would be bounded by is not
          # the subject. `ServiceRadar.Edge.PublishPipelineTest` covers that half.
          [class: :bulk, pool: nil, publisher: publisher, task_supervisor: tasks, name: nil] ++ opts
        },
        id: make_ref()
      )

    Application.put_env(:serviceradar_agent_gateway, :edge_record_ingest_pipelines, %{bulk: pipeline})
    pipeline
  end
end
