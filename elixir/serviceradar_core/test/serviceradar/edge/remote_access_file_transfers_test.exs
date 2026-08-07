defmodule ServiceRadar.Edge.RemoteAccessFileTransfersTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessFileTransfers
  alias ServiceRadar.Edge.RemoteAccessSession

  @moduletag :requires_app

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

    def get_by_id(transfer_id, _opts) do
      case Process.get(:remote_access_file_transfer_lookup) do
        %{id: ^transfer_id} = transfer -> {:ok, transfer}
        _other -> {:error, :not_found}
      end
    end

    def list_by_session(session_id, _opts) do
      send(Process.get(:remote_access_file_transfer_owner), {:list_transfers, session_id})
      {:ok, Process.get(:remote_access_file_transfer_list, [])}
    end

    def mark_started(transfer, attrs, _opts), do: update_transfer(transfer, attrs, :started)

    def record_progress(transfer, attrs, _opts),
      do: update_transfer(transfer, attrs, :in_progress)

    def finish(transfer, attrs, _opts), do: update_transfer(transfer, attrs, :completed)
    def deny(transfer, attrs, _opts), do: update_transfer(transfer, attrs, :denied)
    def fail(transfer, attrs, _opts), do: update_transfer(transfer, attrs, :failed)
    def cancel(transfer, attrs, _opts), do: update_transfer(transfer, attrs, :canceled)

    def quota_exhausted(transfer, attrs, _opts),
      do: update_transfer(transfer, attrs, :quota_exhausted)

    defp update_transfer(transfer, attrs, status) do
      updated = transfer |> Map.merge(attrs) |> Map.put(:status, status)
      send(Process.get(:remote_access_file_transfer_owner), {:update_transfer, status, attrs})
      {:ok, updated}
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

  defmodule RecordingsStub do
    @moduledoc false

    def record_event(recording, attrs, opts) do
      send(
        Process.get(:remote_access_file_transfer_owner),
        {:record_event, recording, attrs, opts}
      )

      {:ok, %{recording_id: recording.id, event_type: attrs.event_type}}
    end
  end

  defmodule AuditWriterStub do
    @moduledoc false

    def write_async(opts) do
      send(Process.get(:remote_access_file_transfer_owner), {:audit, opts})
      :ok
    end
  end

  defmodule ApprovalCheckerStub do
    @moduledoc false

    def authorize_file_transfer_completion(context, _opts) do
      send(Process.get(:remote_access_file_transfer_owner), {:approval_revalidated, context})
      Process.get(:remote_access_file_transfer_approval_result, :ok)
    end
  end

  setup do
    Process.put(:remote_access_file_transfer_owner, self())

    :ok
  end

  test "routes transfer request over the selected session agent and gateway" do
    session_id = Ecto.UUID.generate()
    actor_id = Ecto.UUID.generate()

    Process.put(
      :remote_access_file_transfer_session,
      %{
        session_fixture(session_id)
        | metadata: %{
            "file_transfer_policy" => %{
              "allowed_operations" => ["download"],
              "allowed_path_rules" => ["/var/log"],
              "max_bytes" => 10_000
            }
          }
      }
    )

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
               recordings: RecordingsStub,
               recording: recording_fixture(session_id),
               audit_writer: AuditWriterStub,
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
             "display_name" => "syslog",
             "policy" => %{
               "allowed_operations" => ["download"],
               "allowed_path_rules" => ["/var/log"],
               "max_bytes" => 10_000
             },
             "approved" => false
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

    assert_receive {:record_event, recording,
                    %{
                      stream: :event,
                      event_type: "transfer_requested",
                      payload: replay_payload
                    }, _recording_opts}

    assert recording.session_id == session_id
    assert replay_payload["event"] == "transfer_requested"
    assert replay_payload["transfer_id"] == transfer.id
    assert replay_payload["redacted_path"] == "/var/log/syslog"
    refute Map.has_key?(replay_payload, :target_path)

    assert_receive {:audit, audit_opts}

    assert audit_opts[:action] == :remote_access_file_transfer_allowed
    assert audit_opts[:resource_type] == "remote_access_file_transfer"
    audit_transfer_id = audit_opts[:resource_id]
    audit_details = audit_opts[:details]
    assert audit_transfer_id == transfer.id
    assert audit_details.session_id == session_id
    assert audit_details.redacted_path == "/var/log/syslog"
    refute Map.has_key?(audit_details, :target_path)
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

  test "dispatches approved transfer requests with approval id for agent echo" do
    session_id = Ecto.UUID.generate()
    approval_id = Ecto.UUID.generate()

    Process.put(:remote_access_file_transfer_session, %{
      session_fixture(session_id)
      | approval_id: approval_id,
        metadata: %{
          "file_transfer_policy" => %{
            "allowed_operations" => ["download"],
            "allowed_path_rules" => ["/var/log"]
          }
        }
    })

    assert {:ok, transfer} =
             RemoteAccessFileTransfers.request_transfer(
               session_id,
               %{operation: "download", direction: "read", path: "/var/log/syslog"},
               session_resource: SessionResourceStub,
               transfer_resource: TransferResourceStub,
               command_bus: CommandBusStub,
               audit_writer: AuditWriterStub,
               required_gateway_node: self()
             )

    assert transfer.approval_id == approval_id

    assert_receive {:send_console_frame, "agent-1",
                    %{frame_type: "file_transfer_request"} = frame, _opts}

    assert %{
             "approved" => true,
             "approval_id" => ^approval_id
           } = Jason.decode!(frame.data)
  end

  test "rejects unsafe remote paths before creating or dispatching a transfer" do
    session_id = Ecto.UUID.generate()
    Process.put(:remote_access_file_transfer_session, session_fixture(session_id))

    assert {:error, :invalid_file_transfer_path} =
             RemoteAccessFileTransfers.request_transfer(
               session_id,
               %{operation: "download", direction: "read", path: "/var/log/../shadow"},
               session_resource: SessionResourceStub,
               transfer_resource: TransferResourceStub,
               command_bus: CommandBusStub,
               required_gateway_node: self()
             )

    refute_receive {:create_transfer, _attrs}
    refute_receive {:send_console_frame, _agent_id, _frame, _opts}
  end

  test "emits metadata-only replay and audit events for lifecycle outcomes" do
    session_id = Ecto.UUID.generate()
    transfer = transfer_fixture(session_id)

    opts = [
      transfer_resource: TransferResourceStub,
      recordings: RecordingsStub,
      recording: recording_fixture(session_id),
      audit_writer: AuditWriterStub,
      audit_actor: %{id: Ecto.UUID.generate(), email: "alice@example.test"}
    ]

    assert {:ok, started} = RemoteAccessFileTransfers.mark_started(transfer, opts)
    assert started.status == :started

    assert_receive {:record_event, _recording, %{event_type: "transfer_started"} = started_event,
                    _opts}

    assert_metadata_only(started_event)
    refute_receive {:audit, %{action: :remote_access_file_transfer_started}}

    assert {:ok, progress} =
             RemoteAccessFileTransfers.record_progress(started, %{byte_count: 4096}, opts)

    assert progress.status == :in_progress

    assert_receive {:record_event, _recording,
                    %{event_type: "transfer_progress", byte_count: 4096} = progress_event, _opts}

    assert_metadata_only(progress_event)

    assert {:ok, completed} =
             RemoteAccessFileTransfers.finish(progress, %{byte_count: 8192, file_count: 1}, opts)

    assert completed.status == :completed

    assert_receive {:record_event, _recording,
                    %{event_type: "transfer_completed"} = completed_event, _opts}

    assert_metadata_only(completed_event)

    assert_receive {:audit, completed_audit}

    assert completed_audit[:action] == :remote_access_file_transfer_completed
    completed_details = completed_audit[:details]
    assert completed_details.byte_count == 8192
    assert completed_details.content_audit_retained == false
    refute Map.has_key?(completed_details, :content_artifact_ref)
    assert_metadata_only(completed_details)

    assert {:ok, denied} = RemoteAccessFileTransfers.deny(transfer, :policy_denied, opts)
    assert denied.status == :denied

    assert_receive {:record_event, _recording, %{event_type: "transfer_denied"} = denied_event,
                    _opts}

    assert_metadata_only(denied_event)
    assert_receive {:audit, denied_audit}
    assert denied_audit[:action] == :remote_access_file_transfer_denied
    assert denied_audit[:severity] == :high

    assert {:ok, failed} = RemoteAccessFileTransfers.fail(transfer, "target refused SFTP", opts)
    assert failed.status == :failed

    assert_receive {:record_event, _recording, %{event_type: "transfer_failed"} = failed_event,
                    _opts}

    assert_metadata_only(failed_event)
    assert_receive {:audit, failed_audit}
    assert failed_audit[:action] == :remote_access_file_transfer_failed
    assert failed_audit[:severity] == :high

    assert {:ok, canceled} = RemoteAccessFileTransfers.cancel(transfer, :user_canceled, opts)
    assert canceled.status == :canceled

    assert_receive {:record_event, _recording,
                    %{event_type: "transfer_canceled"} = canceled_event, _opts}

    assert_metadata_only(canceled_event)
    assert_receive {:audit, canceled_audit}
    assert canceled_audit[:action] == :remote_access_file_transfer_canceled

    assert {:ok, exhausted} =
             RemoteAccessFileTransfers.quota_exhausted(transfer, :byte_quota, opts)

    assert exhausted.status == :quota_exhausted

    assert_receive {:record_event, _recording,
                    %{event_type: "transfer_quota_exhausted"} = exhausted_event, _opts}

    assert_metadata_only(exhausted_event)
    assert_receive {:audit, exhausted_audit}
    assert exhausted_audit[:action] == :remote_access_file_transfer_quota_exhausted
    assert exhausted_audit[:severity] == :high
  end

  test "handles agent outcome frames as metadata-only lifecycle updates" do
    session_id = Ecto.UUID.generate()
    transfer = transfer_fixture(session_id)
    Process.put(:remote_access_file_transfer_lookup, transfer)

    opts = [
      transfer_resource: TransferResourceStub,
      recordings: RecordingsStub,
      recording: recording_fixture(session_id),
      audit_writer: AuditWriterStub
    ]

    frame = %{
      session_id: session_id,
      frame_type: "file_transfer_outcome",
      data:
        Jason.encode!(%{
          transfer_id: transfer.id,
          status: "completed",
          bytes_transferred: 2048,
          files_transferred: 1,
          sha256: String.duplicate("b", 64),
          content_audit_retained: false,
          content_artifact_ref: %{bucket: "should-not-appear", object_key: "raw/file"}
        })
    }

    assert {:ok, updated} = RemoteAccessFileTransfers.handle_agent_frame(frame, opts)
    assert updated.status == :completed
    assert updated.byte_count == 2048
    assert updated.file_count == 1

    assert_receive {:update_transfer, :completed, attrs}
    assert attrs.byte_count == 2048
    assert attrs.file_count == 1

    assert_receive {:record_event, _recording,
                    %{event_type: "transfer_completed"} = completed_event, _opts}

    assert_metadata_only(completed_event)

    assert_receive {:audit, audit_opts}
    assert audit_opts[:action] == :remote_access_file_transfer_completed
    assert_metadata_only(audit_opts[:details])
    refute Map.has_key?(audit_opts[:details], :content_artifact_ref)
  end

  test "terminal agent outcome frames must echo and revalidate approval id" do
    session_id = Ecto.UUID.generate()
    approval_id = Ecto.UUID.generate()
    transfer = Map.put(transfer_fixture(session_id), :approval_id, approval_id)
    Process.put(:remote_access_file_transfer_lookup, transfer)

    opts = [
      transfer_resource: TransferResourceStub,
      approval_checker: ApprovalCheckerStub,
      recordings: RecordingsStub,
      recording: recording_fixture(session_id),
      audit_writer: AuditWriterStub
    ]

    missing_approval_frame = %{
      session_id: session_id,
      frame_type: "file_transfer_outcome",
      data: Jason.encode!(%{transfer_id: transfer.id, status: "completed"})
    }

    assert {:error, :file_transfer_approval_mismatch} =
             RemoteAccessFileTransfers.handle_agent_frame(missing_approval_frame, opts)

    refute_receive {:update_transfer, :completed, _attrs}
    refute_receive {:approval_revalidated, _context}

    Process.put(:remote_access_file_transfer_approval_result, {:error, :approval_denied})

    denied_frame = %{
      session_id: session_id,
      frame_type: "file_transfer_outcome",
      data:
        Jason.encode!(%{
          transfer_id: transfer.id,
          approval_id: approval_id,
          status: "completed"
        })
    }

    assert {:error, :approval_denied} =
             RemoteAccessFileTransfers.handle_agent_frame(denied_frame, opts)

    assert_receive {:approval_revalidated,
                    %{
                      approval_id: ^approval_id,
                      session_id: ^session_id,
                      transfer_id: transfer_id
                    }}

    assert transfer_id == transfer.id
    refute_receive {:update_transfer, :completed, _attrs}
  end

  test "rejects agent file transfer frames for the wrong session" do
    transfer = transfer_fixture(Ecto.UUID.generate())
    Process.put(:remote_access_file_transfer_lookup, transfer)

    frame = %{
      session_id: Ecto.UUID.generate(),
      frame_type: "file_transfer_outcome",
      data: Jason.encode!(%{transfer_id: transfer.id, status: "completed"})
    }

    assert {:error, :file_transfer_session_mismatch} =
             RemoteAccessFileTransfers.handle_agent_frame(frame,
               transfer_resource: TransferResourceStub
             )

    refute_receive {:update_transfer, _status, _attrs}
  end

  test "rechecks approval before accepting terminal agent frames" do
    session_id = Ecto.UUID.generate()
    approval_id = Ecto.UUID.generate()
    transfer = Map.put(transfer_fixture(session_id), :approval_id, approval_id)
    Process.put(:remote_access_file_transfer_lookup, transfer)

    frame = %{
      session_id: session_id,
      frame_type: "file_transfer_outcome",
      data: Jason.encode!(%{transfer_id: transfer.id, status: "completed"})
    }

    assert {:error, :file_transfer_approval_mismatch} =
             RemoteAccessFileTransfers.handle_agent_frame(frame,
               transfer_resource: TransferResourceStub,
               approval_checker: ApprovalCheckerStub
             )

    refute_receive {:update_transfer, _status, _attrs}

    approved_frame = %{
      frame
      | data:
          Jason.encode!(%{
            transfer_id: transfer.id,
            approval_id: approval_id,
            status: "completed",
            bytes_transferred: 128
          })
    }

    assert {:ok, updated} =
             RemoteAccessFileTransfers.handle_agent_frame(approved_frame,
               transfer_resource: TransferResourceStub,
               approval_checker: ApprovalCheckerStub,
               recording: nil,
               audit_writer: AuditWriterStub
             )

    assert updated.status == :completed
    assert_receive {:approval_revalidated, %{approval_id: ^approval_id, session_id: ^session_id}}
    assert_receive {:update_transfer, :completed, %{byte_count: 128}}
  end

  test "lists transfer history through the Ash resource boundary" do
    session_id = Ecto.UUID.generate()
    transfer = transfer_fixture(session_id)
    Process.put(:remote_access_file_transfer_list, [transfer])

    assert {:ok, [^transfer]} =
             RemoteAccessFileTransfers.list_transfers(session_id,
               transfer_resource: TransferResourceStub,
               scope: %{user: %{id: Ecto.UUID.generate()}}
             )

    assert_receive {:list_transfers, ^session_id}
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

  defp transfer_fixture(session_id) do
    %{
      id: Ecto.UUID.generate(),
      session_id: session_id,
      requested_by: Ecto.UUID.generate(),
      device_uid: "device-1",
      target_kind: :inventory_device,
      target_host: "10.0.0.10",
      target_port: 22,
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      operation: :download,
      direction: :read,
      protocol: :sftp,
      credential_custody_mode: :ssh_certificate,
      target_path: "/var/log/sensitive.log",
      redacted_path: "REDACTED",
      path_hash: String.duplicate("a", 64),
      byte_count: 0,
      file_count: 0,
      policy_decision: %{allowed: true, content_audit_retain: false},
      quota_snapshot: %{max_bytes: 10_000},
      content_audit_retained: false,
      content_artifact_ref: %{bucket: "should-not-appear", object_key: "raw/file"},
      status: :requested
    }
  end

  defp recording_fixture(session_id) do
    %{id: Ecto.UUID.generate(), session_id: session_id}
  end

  defp assert_metadata_only(value) do
    rendered = inspect(value)

    refute rendered =~ "/var/log/sensitive.log"
    refute rendered =~ "should-not-appear"
    refute rendered =~ "raw/file"
    refute rendered =~ "file contents"
  end
end
