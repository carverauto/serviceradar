defmodule ServiceRadar.SPIFFE.CertMonitor do
  @moduledoc """
  Periodically checks SPIFFE certificate expiry and emits telemetry.

  The monitor logs warnings when the SVID approaches expiration and
  emits `[:serviceradar, :spiffe, :cert_expiry]` telemetry events with
  the remaining lifetime.
  """

  use GenServer

  require Logger

  alias ServiceRadar.SPIFFE

  @default_check_interval_seconds 600
  @default_warn_threshold_seconds 86_400
  @default_critical_threshold_seconds 21_600

  defstruct [
    :cert_dir,
    :check_interval,
    :warn_threshold,
    :critical_threshold,
    :last_status,
    :last_expires_at
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      cert_dir: Keyword.get(opts, :cert_dir, SPIFFE.cert_dir()),
      check_interval: read_interval("SPIFFE_CERT_MONITOR_INTERVAL_SECONDS", @default_check_interval_seconds),
      warn_threshold: read_interval("SPIFFE_CERT_WARN_SECONDS", @default_warn_threshold_seconds),
      critical_threshold: read_interval("SPIFFE_CERT_CRITICAL_SECONDS", @default_critical_threshold_seconds),
      last_status: nil,
      last_expires_at: nil
    }

    _ = start_watch(state)
    send(self(), :check)

    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    new_state = check_cert(state)
    Process.send_after(self(), :check, state.check_interval * 1_000)
    {:noreply, new_state}
  end

  defp start_watch(%__MODULE__{} = state) do
    _ =
      SPIFFE.watch_certificates(
        callback: fn ->
          send(self(), :check)
        end,
        poll_interval: state.check_interval * 1_000
      )

    :ok
  end

  defp check_cert(%__MODULE__{} = state) do
    case SPIFFE.cert_expiry(cert_dir: state.cert_dir) do
      {:ok, info} ->
        status = classify(info.seconds_remaining, state.warn_threshold, state.critical_threshold)
        maybe_log(status, info, state)
        emit_telemetry(status, info)

        %{state | last_status: status, last_expires_at: info.expires_at}

      {:error, reason} ->
        status = :unknown
        maybe_log(status, %{reason: reason}, state)
        emit_error_telemetry(reason)
        %{state | last_status: status}
    end
  end

  defp classify(seconds_remaining, warn_threshold, critical_threshold) do
    cond do
      seconds_remaining <= 0 -> :expired
      seconds_remaining <= critical_threshold -> :critical
      seconds_remaining <= warn_threshold -> :warning
      true -> :ok
    end
  end

  defp maybe_log(status, info, %__MODULE__{last_status: last_status, last_expires_at: last_expires_at}) do
    expires_at =
      case info do
        %{expires_at: value} -> value
        _ -> nil
      end

    if status != last_status or expires_at != last_expires_at do
      log_status(status, info)
    end
  end

  defp log_status(:ok, info) do
    Logger.info("SPIFFE certificate OK, expires at #{format_expires_at(info)}")
  end

  defp log_status(:warning, info) do
    Logger.warning("SPIFFE certificate expiring soon: #{format_expiry(info)}")
  end

  defp log_status(:critical, info) do
    Logger.error("SPIFFE certificate nearing expiry: #{format_expiry(info)}")
  end

  defp log_status(:expired, info) do
    Logger.error("SPIFFE certificate expired: #{format_expiry(info)}")
  end

  defp log_status(:unknown, %{reason: reason}) do
    Logger.warning("SPIFFE certificate expiry unavailable: #{inspect(reason)}")
  end

  defp format_expiry(%{expires_at: expires_at, seconds_remaining: seconds}) do
    "#{expires_at} (#{seconds} seconds remaining)"
  end

  defp format_expires_at(%{expires_at: expires_at}), do: expires_at
  defp format_expires_at(_), do: "unknown"

  defp emit_telemetry(status, %{seconds_remaining: seconds, expires_at: expires_at, days_remaining: days}) do
    :telemetry.execute(
      [:serviceradar, :spiffe, :cert_expiry],
      %{seconds_remaining: seconds, days_remaining: days},
      %{status: status, expires_at: expires_at}
    )
  end

  defp emit_error_telemetry(reason) do
    :telemetry.execute(
      [:serviceradar, :spiffe, :cert_expiry],
      %{seconds_remaining: nil, days_remaining: nil},
      %{status: :unknown, error: reason}
    )
  end

  defp read_interval(env_var, default) do
    case System.get_env(env_var) do
      nil -> default
      value ->
        case Integer.parse(value) do
          {int, _} when int > 0 -> int
          _ -> default
        end
    end
  end
end
