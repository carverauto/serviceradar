defmodule ServiceRadarAgentGateway.ControlStreamSessionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.ProxmoxConsolePubSub
  alias ServiceRadar.Edge.RemoteAccessPubSub
  alias ServiceRadarAgentGateway.ControlStreamSession

  test "agent console frames are broadcast to proxmox and generic remote-access subscribers" do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    session_id = "session-#{System.unique_integer([:positive])}"

    :ok = ProxmoxConsolePubSub.subscribe(session_id)
    :ok = RemoteAccessPubSub.subscribe(session_id)

    pid = start_supervised!({ControlStreamSession, stream: nil})

    ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
      payload:
        {:console_frame,
         %Monitoring.ConsoleFrame{
           session_id: session_id,
           frame_type: "data",
           data: "hello",
           timestamp: 123
         }}
    })

    assert_receive {:proxmox_console_frame, %{session_id: ^session_id, frame_type: "data", data: "hello"}}
    assert_receive {:remote_access_frame, %{session_id: ^session_id, frame_type: "data", data: "hello"}}
  end
end
