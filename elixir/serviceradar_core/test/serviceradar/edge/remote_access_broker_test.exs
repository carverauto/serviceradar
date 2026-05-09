defmodule ServiceRadar.Edge.RemoteAccessBrokerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessBroker

  defmodule CommandBusStub do
    @moduledoc false

    def send_console_frame(agent_id, frame, opts) do
      send(
        Keyword.fetch!(opts, :required_gateway_node),
        {:send_console_frame, agent_id, frame, opts}
      )

      :ok
    end
  end

  defmodule PubSubStub do
    @moduledoc false

    def subscribe(_session_id), do: :ok
  end

  test "opens generic SSH sessions over the existing console frame path" do
    session = session_fixture()

    pid =
      start_supervised!(
        {RemoteAccessBroker,
         {session, self(),
          command_bus: CommandBusStub,
          pubsub: PubSubStub,
          required_gateway_node: self(),
          cols: 132,
          rows: 43}}
      )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = frame, opts}
    assert opts[:required_gateway_node] == self()
    assert frame.cols == 132
    assert frame.rows == 43

    assert %{
             "protocol" => "ssh",
             "session_id" => "session-1",
             "agent_id" => "agent-1",
             "gateway_id" => "gateway-1",
             "credential_mode" => "agent_local",
             "credential_ref" => "ssh/root@host-1",
             "ssh_host_key_policy" => "skip_verify",
             "target" => %{"host" => "10.0.0.10", "port" => 22},
             "ssh" => %{"username" => "root"}
           } = Jason.decode!(frame.data)

    assert :ok = RemoteAccessBroker.send_input(pid, "whoami\r")

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "data", data: "whoami\r"},
                    _opts}

    assert :ok = RemoteAccessBroker.resize(pid, 120, 34)

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "resize", cols: 120, rows: 34},
                    _opts}

    RemoteAccessBroker.close(pid, :operator_closed)

    assert_receive {:send_console_frame, "agent-1",
                    %{frame_type: "close", reason: ":operator_closed"}, _opts}
  end

  test "forwards remote-access data and close frames to the owner" do
    session = session_fixture()

    pid =
      start_supervised!(
        {RemoteAccessBroker,
         {session, self(),
          command_bus: CommandBusStub, pubsub: PubSubStub, required_gateway_node: self()}}
      )

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"}, _opts}

    send(pid, {:remote_access_frame, %{frame_type: "data", data: "hello"}})
    assert_receive {:remote_access_data, "hello"}

    send(pid, {:remote_access_frame, %{frame_type: "close", reason: "done"}})
    assert_receive {:remote_access_closed, "done"}
  end

  defp session_fixture do
    %{
      id: "session-1",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      metadata: %{
        "credential_ref" => "ssh/root@host-1",
        "target" => %{"host" => "10.0.0.10", "port" => 22},
        "ssh" => %{"username" => "root"}
      }
    }
  end
end
