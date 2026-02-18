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
    params = progress_params(data)

    case progress_transition(session, message) do
      {:transition, action} -> transition(session, action, %{}, actor)
      :none -> persist_progress_update(session, params, actor)
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

  defp progress_params(data) do
    payload = Map.get(data, :payload, %{})

    %{}
    |> maybe_put(:bytes_transferred, Map.get(payload, "bytes_transferred"))
    |> maybe_put(:transfer_rate, Map.get(payload, "transfer_rate"))
  end

  defp progress_transition(%{status: :queued, mode: :receive}, _message),
    do: {:transition, :start_waiting}

  defp progress_transition(%{status: :waiting}, message) when is_binary(message) do
    if String.contains?(message, "receiving"), do: {:transition, :start_receiving}, else: :none
  end

  defp progress_transition(%{status: :queued, mode: :serve}, _message),
    do: {:transition, :start_staging}

  defp progress_transition(%{status: :staging}, message) when is_binary(message) do
    if String.contains?(message, "ready"), do: {:transition, :mark_ready}, else: :none
  end

  defp progress_transition(%{status: :ready}, message) when is_binary(message) do
    if String.contains?(message, "serving"), do: {:transition, :start_serving}, else: :none
  end

  defp progress_transition(_, _), do: :none

  defp persist_progress_update(_session, params, _actor) when params == %{}, do: :ok

  defp persist_progress_update(session, params, actor) do
    case Ash.update(session, action: :update_progress, params: params, actor: actor) do
      {:ok, updated} ->
        TftpPubSub.broadcast_session_progress(updated.id, params)
        :ok

      _ ->
        :ok
    end
  end
end
