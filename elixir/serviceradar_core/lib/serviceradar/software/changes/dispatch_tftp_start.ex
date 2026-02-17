defmodule ServiceRadar.Software.Changes.DispatchTftpStart do
  @moduledoc """
  Dispatches a TFTP start command when a session transitions to :queued.

  For receive-mode sessions: dispatches `tftp.start_receive`
  For serve-mode sessions: dispatches `tftp.start_serve`
  """

  use Ash.Resource.Change

  require Logger

  alias ServiceRadar.Edge.AgentCommandBus

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      command_type =
        case record.mode do
          :receive -> "tftp.start_receive"
          :serve -> "tftp.start_serve"
        end

      payload = %{
        session_id: record.id,
        mode: to_string(record.mode),
        expected_filename: record.expected_filename,
        timeout_seconds: record.timeout_seconds,
        bind_address: record.bind_address,
        port: record.port,
        max_file_size: record.max_file_size
      }

      opts = [
        required_capability: "tftp",
        ttl_seconds: record.timeout_seconds + 30,
        context: %{tftp_session_id: record.id, mode: to_string(record.mode)}
      ]

      case AgentCommandBus.dispatch(record.agent_id, command_type, payload, opts) do
        {:ok, command_id} ->
          Logger.info(
            "TFTP session dispatched",
            session_id: record.id,
            agent_id: record.agent_id,
            command_type: command_type,
            command_id: command_id,
            filename: record.expected_filename
          )

          {:ok, record}

        {:error, reason} ->
          Logger.error(
            "TFTP session dispatch failed",
            session_id: record.id,
            agent_id: record.agent_id,
            command_type: command_type,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :not_atomic
end
