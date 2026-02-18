defmodule ServiceRadar.Software.Changes.DispatchTftpStop do
  @moduledoc """
  Dispatches a `tftp.stop_session` command when a session is canceled.
  """

  use Ash.Resource.Change

  require Logger

  alias ServiceRadar.Edge.AgentCommandBus

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      payload = %{
        session_id: record.id
      }

      opts = [
        required_capability: "tftp",
        context: %{tftp_session_id: record.id}
      ]

      Logger.info(
        "TFTP session canceled",
        session_id: record.id,
        agent_id: record.agent_id
      )

      previous_status = changeset.data.status

      # Configuring sessions never started on the agent, so there is no
      # remote session to stop. Avoid dispatching and just persist cancel.
      if previous_status == :configuring do
        {:ok, record}
      else
        case safe_dispatch_stop(record.agent_id, payload, opts) do
          {:ok, _command_id} ->
            {:ok, record}

          {:error, reason} ->
            Logger.warning(
              "Ignoring tftp.stop_session dispatch failure during cancel",
              session_id: record.id,
              agent_id: record.agent_id,
              reason: inspect(reason)
            )

            {:ok, record}
        end
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :not_atomic

  defp safe_dispatch_stop(agent_id, payload, opts) do
    try do
      AgentCommandBus.dispatch(agent_id, "tftp.stop_session", payload, opts)
    catch
      :exit, reason ->
        {:error, {:dispatch_exit, reason}}
    end
  end
end
