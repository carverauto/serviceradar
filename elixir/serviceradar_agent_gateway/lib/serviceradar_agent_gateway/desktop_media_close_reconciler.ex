defmodule ServiceRadarAgentGateway.DesktopMediaCloseReconciler do
  @moduledoc """
  Retries core-owned desktop media cleanup obligations.

  The session tracker is a separately supervised process, so a reconciler
  crash does not discard pending work. A whole gateway loss is covered by the
  core ingress idle-owner lifecycle, which closes viewers when frames stop.
  """

  use GenServer

  alias ServiceRadarAgentGateway.DesktopMediaForwarder
  alias ServiceRadarAgentGateway.DesktopMediaSessionTracker

  require Logger

  @default_interval_ms 5_000

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def reconcile_now(server \\ __MODULE__) do
    GenServer.call(server, :reconcile_now)
  end

  @impl true
  def init(opts) do
    interval_ms = normalize_interval(Keyword.get(opts, :interval_ms, configured_interval()))

    state = %{
      tracker: Keyword.get(opts, :tracker, DesktopMediaSessionTracker),
      forwarder: Keyword.get(opts, :forwarder, DesktopMediaForwarder),
      interval_ms: interval_ms
    }

    schedule_reconcile(interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:reconcile_now, _from, state) do
    {:reply, reconcile(state), state}
  end

  @impl true
  def handle_info(:reconcile_pending_desktop_media_closes, state) do
    _ = reconcile(state)
    schedule_reconcile(state.interval_ms)
    {:noreply, state}
  end

  defp reconcile(state) do
    sessions = state.tracker.pending_core_cleanups()

    reconciled =
      Enum.reduce(sessions, 0, &reconcile_session(&1, &2, state))

    {:ok, reconciled}
  rescue
    error ->
      Logger.warning("Desktop media close reconciliation failed",
        reason: Exception.message(error)
      )

      {:error, :reconciliation_failed}
  catch
    :exit, reason ->
      Logger.warning("Desktop media close reconciliation exited",
        reason: inspect(reason)
      )

      {:error, :reconciliation_failed}
  end

  defp reconcile_session(session, count, state) do
    case close_core(state.forwarder, session.desktop_session_id) do
      :ok ->
        complete_pending_core_cleanup(state.tracker, session, count)

      {:error, reason} ->
        log_failure(session.desktop_session_id, reason)
        count
    end
  end

  defp complete_pending_core_cleanup(tracker, session, count) do
    case tracker.complete_pending_core_cleanup(
           session.desktop_session_id,
           session.media_session_id,
           session.agent_id,
           %{media_ingest_id: session.media_ingest_id}
         ) do
      :ok ->
        count + 1

      {:error, :not_found} ->
        count

      {:error, reason} ->
        log_failure(session.desktop_session_id, {:tracker_completion_failed, reason})
        count
    end
  end

  defp close_core(forwarder, desktop_session_id) do
    case forwarder.close_session(desktop_session_id) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_close_response, other}}
    end
  rescue
    error -> {:error, {:cleanup_raised, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:cleanup_exited, reason}}
  end

  defp log_failure(desktop_session_id, reason) do
    Logger.warning("Desktop media core cleanup remains pending",
      desktop_session_id: safe_log_identifier(desktop_session_id),
      reason: inspect(reason)
    )
  end

  defp safe_log_identifier(value) when is_binary(value) do
    if byte_size(value) <= 128 and Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, value),
      do: value,
      else: "invalid"
  end

  defp safe_log_identifier(_value), do: "invalid"

  defp configured_interval do
    Application.get_env(
      :serviceradar_agent_gateway,
      :desktop_media_close_reconcile_interval_ms,
      @default_interval_ms
    )
  end

  defp schedule_reconcile(:disabled), do: :ok

  defp schedule_reconcile(interval_ms) do
    Process.send_after(self(), :reconcile_pending_desktop_media_closes, interval_ms)
    :ok
  end

  defp normalize_interval(:disabled), do: :disabled
  defp normalize_interval(value) when is_integer(value) and value > 0, do: value
  defp normalize_interval(_value), do: @default_interval_ms
end
