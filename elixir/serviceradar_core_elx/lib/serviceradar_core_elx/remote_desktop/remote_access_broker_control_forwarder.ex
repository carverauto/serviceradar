defmodule ServiceRadarCoreElx.RemoteDesktop.RemoteAccessBrokerControlForwarder do
  @moduledoc """
  Routes browser desktop control frames from core-elx to the active broker.

  WebRTC DataChannel control messages terminate in core-elx, but the selected
  agent route is owned by the browser-attached `RemoteAccessBroker`. This
  forwarder resolves that broker by remote-access session ID and asks it to send
  the typed desktop control frame over the existing selected control stream.
  """

  alias ServiceRadar.Edge.RemoteAccessBroker
  alias ServiceRadar.Edge.RemoteAccessBrokerRegistry

  @spec forward_browser_control(map(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def forward_browser_control(session, _viewer_session_id, frame, opts)
      when is_map(session) and is_map(frame) and is_list(opts) do
    broker_registry = Keyword.get(opts, :broker_registry, RemoteAccessBrokerRegistry)
    broker_module = Keyword.get(opts, :broker_module, RemoteAccessBroker)

    with {:ok, session_id} <- session_id(session),
         {:ok, broker, _metadata} <- broker_registry.lookup(session_id) do
      broker_module.send_desktop_control(broker, frame)
    end
  end

  defp session_id(session) do
    case Map.get(session, :session_id) || Map.get(session, "session_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_remote_access_session}
    end
  end
end
