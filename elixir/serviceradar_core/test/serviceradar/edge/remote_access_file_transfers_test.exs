defmodule ServiceRadar.Edge.RemoteAccessFileTransfersTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessFileTransfers
  alias ServiceRadar.Edge.RemoteAccessSession

  defmodule SessionResourceStub do
    @moduledoc false

    def get_by_id(session_id, _opts) do
      case Process.get(:remote_access_file_transfer_session) do
        nil -> {:error, :not_found}
        session -> {:ok, %{session | id: session_id}}
      end
    end
  end

  defmodule TransferResourceStub do
    @moduledoc false

    def create_transfer(attrs, _opts) do
      transfer = Map.merge(attrs, %{id: Ecto.UUID.generate(), status: :requested})
      send(Process.get(:remote_access_file_transfer_owner), {:create_transfer, attrs})
      {:ok, transfer}
    end
  end

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

  setup do
    Process.put(:remote_access_file_transfer_owner, self())

    :ok
  end

  test "routes transfer request over the selected session agent and gateway" do
    session_id = Ecto.UUID.generate()
    actor_id = Ecto.UUID.generate()

    Process.put(:remote_access_file_transfer_session, session_fixture(session_id))

    request = %{
      operation: "download",
      direction: "read",
      path: "/var/log/syslog",
      destination_path: nil,
      display_name: "syslog"
    }

    assert {:ok, transfer} =
             RemoteAccessFileTransfers.request_transfer(session_id, request,
               session_resource: SessionResourceStub,
               transfer_resource: TransferResourceStub,
               command_bus: CommandBusStub,
               required_gateway_node: self(),
               scope: %{user: %{id: actor_id}}
             )

    assert transfer.session_id == session_id
    assert transfer.agent_id == "agent-1"
    assert transfer.gateway_id == "gateway-1"
    assert transfer.credential_custody_mode == :ssh_certificate
    assert transfer.target_path == "/var/log/syslog"

    assert_receive {:create_transfer, attrs}
    assert attrs.session_id == session_id
    assert attrs.requested_by == actor_id
    assert attrs.device_uid == "device-1"
    assert attrs.target_host == "10.0.0.10"
    assert attrs.target_port == 22
    assert attrs.agent_id == "agent-1"
    assert attrs.gateway_id == "gateway-1"
    assert attrs.operation == :download
    assert attrs.direction == :read
    assert attrs.protocol == :sftp
    assert attrs.redacted_path == "/var/log/syslog"
    assert byte_size(attrs.path_hash) == 64
    assert attrs.policy_decision.content_audit_retain == false

    assert_receive {:send_console_frame, "agent-1",
                    %{frame_type: "file_transfer_request"} = frame, opts}

    assert opts[:required_gateway_node] == self()
    assert frame.session_id == session_id

    assert %{
             "protocol" => "sftp",
             "transfer_id" => transfer_id,
             "session_id" => ^session_id,
             "operation" => "download",
             "direction" => "read",
             "path" => "/var/log/syslog",
             "display_name" => "syslog"
           } = Jason.decode!(frame.data)

    assert transfer_id == transfer.id
    refute frame.data =~ "target"
    refute frame.data =~ "agent_id"
    refute frame.data =~ "gateway_id"
    refute frame.data =~ "credential"
    refute frame.data =~ "ssh"
    refute frame.data =~ "approval"
    refute frame.data =~ "quota"
    refute frame.data =~ "recording"
  end

  test "refuses inactive sessions before creating or dispatching a transfer" do
    session_id = Ecto.UUID.generate()

    Process.put(:remote_access_file_transfer_session, %{
      session_fixture(session_id)
      | status: :closed
    })

    assert {:error, :remote_access_session_not_active} =
             RemoteAccessFileTransfers.request_transfer(
               session_id,
               %{operation: "download", direction: "read", path: "/var/log/syslog"},
               session_resource: SessionResourceStub,
               transfer_resource: TransferResourceStub,
               command_bus: CommandBusStub,
               required_gateway_node: self()
             )

    refute_receive {:create_transfer, _attrs}
    refute_receive {:send_console_frame, _agent_id, _frame, _opts}
  end

  defp session_fixture(session_id) do
    %RemoteAccessSession{
      id: session_id,
      status: :active,
      device_uid: "device-1",
      target_kind: :inventory_device,
      target_host: "10.0.0.10",
      target_port: 22,
      protocol: :ssh,
      adapter: :ssh,
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      credential_custody_mode: :ssh_certificate,
      metadata: %{}
    }
  end
end
