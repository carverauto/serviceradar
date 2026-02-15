defmodule ServiceRadar.Software.Changes.DispatchTftpStop do
  @moduledoc """
  Dispatches a `tftp.stop_session` command when a session is canceled.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Edge.AgentCommandBus

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      payload = %{
        session_id: record.id
      }

      opts = [
        required_capability: "tftp",
        context: %{tftp_session_id: record.id}
      ]

      case AgentCommandBus.dispatch(record.agent_id, "tftp.stop_session", payload, opts) do
        {:ok, _command_id} -> {:ok, record}
        {:error, _reason} -> {:ok, record}
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
