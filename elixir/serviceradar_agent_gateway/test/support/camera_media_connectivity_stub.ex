defmodule ServiceRadarAgentGateway.TestSupport.CameraMediaConnectivityStub do
  @moduledoc false

  def ping(node) do
    send(self(), {:core_ping, node})

    case Process.get({__MODULE__, :results}, []) do
      [result | rest] ->
        Process.put({__MODULE__, :results}, rest)
        result

      [] ->
        :pang
    end
  end
end
