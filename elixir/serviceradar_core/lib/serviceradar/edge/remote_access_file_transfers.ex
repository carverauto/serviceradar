defmodule ServiceRadar.Edge.RemoteAccessFileTransfers do
  @moduledoc """
  Remote-access file-transfer orchestration boundary.

  The first implementation slice wires API validation to this boundary. Gateway
  routing and SFTP execution are added in follow-up tasks.
  """

  def request_transfer(_session_id, _request, _opts \\ []) do
    {:error, :not_implemented}
  end
end
