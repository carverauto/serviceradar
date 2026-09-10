defmodule ServiceRadarAgentGateway.TestSupport.EdgeRecordPublisherStub do
  @moduledoc false

  def publish_record(publication, _opts \\ []) do
    send(self(), {:edge_record_published, publication})

    case Process.get(:edge_record_publish_result) do
      nil -> {:ok, %{stream: "TELEMETRY_EDGE_RECORD_V1_BULK", seq: 1, duplicate: false}}
      result -> result
    end
  end
end
