defmodule ServiceRadar.Software.TftpStatusHandler do
  @moduledoc """
  Handles TFTP command results and progress updates, bridging AgentCommand
  lifecycle events to TftpSession state transitions.

  Subscribes to the agent command PubSub and filters for TFTP-related events.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentCommands.PubSub
  alias ServiceRadar.Software.TftpPubSub
  alias ServiceRadar.Software.TftpSession

  require Logger

  @tftp_command_types [
    "tftp.start_receive",
    "tftp.start_serve",
    "tftp.stop_session",
    "tftp.status",
    "tftp.stage_image"
  ]

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    PubSub.subscribe()
    {:ok, Map.put(state, :actor, SystemActor.system(:tftp_status_handler))}
  end

  @impl true
  def handle_info({:command_progress, data}, state) do
    if tftp_command?(data) do
      handle_tftp_progress(data, state.actor)
    end

    {:noreply, state}
  end

  def handle_info({:command_result, data}, state) do
    if tftp_command?(data) do
      handle_tftp_result(data, state.actor)
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp tftp_command?(%{command_type: type}) when type in @tftp_command_types, do: true
  defp tftp_command?(_), do: false

  defp handle_tftp_progress(data, actor) do
    session_id = get_session_id(data)

    if session_id do
      case load_session(session_id, actor) do
        {:ok, session} ->
          update_session_progress(session, data, actor)

        _ ->
          :ok
      end
    end
  end

  defp handle_tftp_result(data, actor) do
    session_id = get_session_id(data)

    if session_id do
      case load_session(session_id, actor) do
        {:ok, session} ->
          apply_result_transition(session, data, actor)

        _ ->
          :ok
      end
    end
  end

  defp update_session_progress(session, data, actor) do
    message = Map.get(data, :message, "")

    params =
      %{}
      |> maybe_put(:bytes_transferred, Map.get(data, :payload, %{}) |> Map.get("bytes_transferred"))
      |> maybe_put(:transfer_rate, Map.get(data, :payload, %{}) |> Map.get("transfer_rate"))

    # Transition based on progress message content
    cond do
      session.status == :queued and session.mode == :receive ->
        transition(session, :start_waiting, %{}, actor)

      session.status == :waiting and String.contains?(message, "receiving") ->
        transition(session, :start_receiving, %{}, actor)

      session.status == :queued and session.mode == :serve ->
        transition(session, :start_staging, %{}, actor)

      session.status == :staging and String.contains?(message, "ready") ->
        transition(session, :mark_ready, %{}, actor)

      session.status == :ready and String.contains?(message, "serving") ->
        transition(session, :start_serving, %{}, actor)

      params != %{} ->
        case Ash.update(session, action: :update_progress, params: params, actor: actor) do
          {:ok, updated} ->
            TftpPubSub.broadcast_session_progress(updated.id, params)
            :ok

          _ ->
            :ok
        end

      true ->
        :ok
    end
  end

  defp apply_result_transition(session, data, actor) do
    success = Map.get(data, :success, false)
    payload = Map.get(data, :payload, %{})

    if success do
      case session.mode do
        :receive ->
          params = %{
            file_size: Map.get(payload, "file_size"),
            content_hash: Map.get(payload, "content_hash")
          }

          transition(session, :complete_receive, params, actor)

        :serve ->
          params = %{
            file_size: Map.get(payload, "file_size")
          }

          transition(session, :complete_serve, params, actor)
      end
    else
      params = %{error_message: Map.get(data, :message, "Unknown error")}
      transition(session, :fail, params, actor)
    end
  end

  defp transition(session, action, params, actor) do
    case Ash.update(session, action: action, params: params, actor: actor) do
      {:ok, updated} ->
        TftpPubSub.broadcast_session_updated(updated)
        :ok

      {:error, reason} ->
        Logger.warning("TftpStatusHandler: failed to transition session",
          session_id: session.id,
          action: action,
          reason: inspect(reason)
        )
    end
  end

  defp load_session(session_id, actor) do
    TftpSession
    |> Ash.Query.for_read(:by_id, %{id: session_id}, actor: actor)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, session} -> {:ok, session}
      error -> error
    end
  end

  defp get_session_id(%{context: %{"tftp_session_id" => id}}), do: id
  defp get_session_id(%{context: %{tftp_session_id: id}}), do: id

  defp get_session_id(%{payload: payload}) when is_map(payload) do
    Map.get(payload, "session_id") || Map.get(payload, :session_id)
  end

  defp get_session_id(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
