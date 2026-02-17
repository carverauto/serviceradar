defmodule ServiceRadar.Software.Changes.DispatchTftpStage do
  @moduledoc """
  Dispatches a `tftp.stage_image` command for serve-mode sessions
  when they transition to :staging.

  This tells the agent to download the software image from core
  so it can serve it via TFTP.
  """

  use Ash.Resource.Change

  require Logger

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
        {:ok, command_id} ->
          Logger.info(
            "TFTP image staging dispatched",
            session_id: record.id,
            agent_id: record.agent_id,
            image_id: record.image_id,
            command_id: command_id
          )

          {:ok, record}

        {:error, reason} ->
          Logger.error(
            "TFTP image staging dispatch failed",
            session_id: record.id,
            agent_id: record.agent_id,
            image_id: record.image_id,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :not_atomic
end
