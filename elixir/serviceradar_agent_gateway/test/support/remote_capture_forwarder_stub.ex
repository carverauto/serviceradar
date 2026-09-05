defmodule ServiceRadarAgentGateway.TestSupport.RemoteCaptureForwarderStub do
  @moduledoc false

  def open_session(request, metadata) do
    notify({:remote_capture_open, self(), request, metadata})
    {:ok, self(), %{initial_credit_bytes: 32}}
  end

  def forward_block(ingress_pid, block) do
    notify({:remote_capture_block, ingress_pid, block})
    :ok
  end

  def forward_state(ingress_pid, state) do
    notify({:remote_capture_state, ingress_pid, state})
    :ok
  end

  def disconnect(ingress_pid, session_id) do
    notify({:remote_capture_disconnect, ingress_pid, session_id})
    :ok
  end

  defp notify(message) do
    case Application.get_env(:serviceradar_agent_gateway, :remote_capture_test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
