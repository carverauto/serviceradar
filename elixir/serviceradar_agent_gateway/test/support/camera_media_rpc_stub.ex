defmodule ServiceRadarAgentGateway.TestSupport.CameraMediaRpcStub do
  @moduledoc false

  def call(node, module, function, args, timeout) do
    send(self(), {:rpc_call, node, module, function, args, timeout})

    case Process.get({__MODULE__, :results}, []) do
      [result | rest] ->
        Process.put({__MODULE__, :results}, rest)
        result

      [] ->
        {:badrpc, :nodedown}
    end
  end
end
