defmodule ServiceRadarAgentGateway.TestSupport.EdgeRecordCapabilityStub do
  @moduledoc false

  def id, do: "edge-records:v1"

  def ready? do
    case Process.get(:edge_record_capability_ready) do
      nil -> true
      value -> value
    end
  end
end
