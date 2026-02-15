defmodule ServiceRadar.Software.Changes.DispatchTftpStage do
  @moduledoc """
  Dispatches a `tftp.stage_image` command for serve-mode sessions
  when they transition to :staging.

  This tells the agent to download the software image from core
  so it can serve it via TFTP.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Edge.AgentCommandBus

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      payload = %{
        session_id: record.id,
        image_id: record.image_id,
        expected_filename: record.expected_filename
      }

      opts = [
        required_capability: "tftp",
        context: %{tftp_session_id: record.id, image_id: record.image_id}
      ]

      case AgentCommandBus.dispatch(record.agent_id, "tftp.stage_image", payload, opts) do
        {:ok, _command_id} -> {:ok, record}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
