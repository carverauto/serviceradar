defmodule ServiceRadarWebNG.TestSupport.RemoteAccessFileTransferManagerStub do
  @moduledoc false

  def list_transfers(session_id, opts) do
    send(test_pid(), {:remote_access_file_transfer_list, session_id, opts})

    {:ok,
     Application.get_env(
       :serviceradar_web_ng,
       :remote_access_file_transfer_manager_list_result,
       [
         %{
           id: Ecto.UUID.generate(),
           session_id: session_id,
           operation: :list,
           direction: :read,
           status: :completed,
           redacted_path: "/var/log",
           path_hash: "path-hash",
           inserted_at: DateTime.utc_now()
         }
       ]
     )}
  end

  def request_transfer(session_id, request, opts) do
    send(test_pid(), {:remote_access_file_transfer, session_id, request, opts})

    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_file_transfer_manager_result,
      {:ok,
       %{
         id: Ecto.UUID.generate(),
         session_id: session_id,
         operation: request.operation,
         direction: request.direction,
         status: :requested,
         redacted_path: request.path,
         path_hash: "path-hash",
         inserted_at: DateTime.utc_now()
       }}
    )
  end

  defp test_pid do
    Application.get_env(:serviceradar_web_ng, :remote_access_file_transfer_manager_test_pid, self())
  end
end
