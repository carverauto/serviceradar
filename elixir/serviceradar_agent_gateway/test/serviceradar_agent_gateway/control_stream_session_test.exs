defmodule ServiceRadarAgentGateway.ControlStreamSessionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.ProxmoxConsolePubSub
  alias ServiceRadar.Edge.RemoteAccessPubSub
  alias ServiceRadarAgentGateway.ControlStreamSession

  test "registered agent console frames are broadcast with authenticated stream ownership" do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    session_id = "session-#{System.unique_integer([:positive])}"

    :ok = ProxmoxConsolePubSub.subscribe(session_id)
    :ok = RemoteAccessPubSub.subscribe(session_id)

    pid = start_supervised!({ControlStreamSession, stream: nil})

    :sys.replace_state(pid, fn state ->
      %{state | agent_id: "agent-owned", partition_id: "partition-a"}
    end)

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

    assert_receive {:proxmox_console_frame,
                    %{
                      session_id: ^session_id,
                      frame_type: "data",
                      data: "hello",
                      agent_id: "agent-owned",
                      partition_id: "partition-a"
                    }}

    assert_receive {:remote_access_frame,
                    %{
                      session_id: ^session_id,
                      frame_type: "data",
                      data: "hello",
                      agent_id: "agent-owned",
                      partition_id: "partition-a"
                    }}
  end

  test "registered agent application and TCP frames stay bound to authenticated stream ownership" do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    session_id = "session-#{System.unique_integer([:positive])}"

    :ok = RemoteAccessPubSub.subscribe(session_id)

    pid = start_supervised!({ControlStreamSession, stream: nil})

    :sys.replace_state(pid, fn state ->
      %{state | agent_id: "agent-owned", partition_id: "partition-a", gateway_node: "gateway-a"}
    end)

    ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
      payload:
        {:console_frame,
         %Monitoring.ConsoleFrame{
           session_id: session_id,
           frame_type: "app_response_metadata",
           data: Jason.encode!(%{request_id: "req-1", status_code: 200}),
           timestamp: 123
         }}
    })

    ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
      payload:
        {:console_frame,
         %Monitoring.ConsoleFrame{
           session_id: session_id,
           frame_type: "tcp_data",
           data: Jason.encode!(%{connection_id: "conn-1", sequence: 1}),
           timestamp: 124
         }}
    })

    assert_receive {:remote_access_frame,
                    %{
                      session_id: ^session_id,
                      frame_type: "app_response_metadata",
                      agent_id: "agent-owned",
                      partition_id: "partition-a",
                      gateway_node: "gateway-a"
                    }}

    assert_receive {:remote_access_frame,
                    %{
                      session_id: ^session_id,
                      frame_type: "tcp_data",
                      agent_id: "agent-owned",
                      partition_id: "partition-a",
                      gateway_node: "gateway-a"
                    }}
  end

  test "unregistered control streams do not broadcast console frames" do
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

    refute_receive {:proxmox_console_frame, _frame}, 50
    refute_receive {:remote_access_frame, _frame}, 50
  end
end
