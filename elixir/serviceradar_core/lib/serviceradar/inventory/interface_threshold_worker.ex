defmodule ServiceRadar.Inventory.InterfaceThresholdWorker do
  @moduledoc """
  Oban worker that evaluates interface threshold conditions and generates alerts.

  Runs periodically to check if any interface metrics exceed configured thresholds.
  When a threshold is violated, it generates an alert via AlertGenerator.

  ## Scheduling

  This worker runs every minute and checks all interfaces with threshold_enabled: true.
  It queries the latest metric values and compares them against configured thresholds.

  ## Threshold Configuration

  Interface thresholds are configured in the InterfaceSettings resource:
  - threshold_enabled: whether threshold alerting is enabled
  - threshold_metric: the metric to evaluate (utilization, bandwidth_in, bandwidth_out, errors)
  - threshold_comparison: comparison operator (gt, lt, gte, lte, eq)
  - threshold_value: the threshold value to compare against

  ## Alert Generation

  When a threshold is violated, an alert is generated with:
  - severity: warning (configurable in future)
  - source_type: :device
  - metric details including interface info
  """

  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.InterfaceSettings
  alias ServiceRadar.Monitoring.AlertGenerator
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger
  require Ash.Query

  # How often to run the evaluator (1 minute)
  @evaluation_interval_seconds 60

  # Cooldown period to avoid duplicate alerts for same interface (5 minutes)
  @alert_cooldown_ms :timer.minutes(5)

  @doc """
  Schedules threshold evaluation if not already scheduled.

  Called automatically on startup or when thresholds are enabled.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      case check_existing_job() do
        true ->
          {:ok, :already_scheduled}

        false ->
          %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  defp check_existing_job do
    import Ecto.Query

    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    ServiceRadar.Repo.exists?(query)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Logger.info("Running interface threshold evaluation")

    case get_enabled_thresholds() do
      {:ok, settings} when settings != [] ->
        Logger.info("Evaluating #{length(settings)} interface thresholds")

        Enum.each(settings, fn setting ->
          evaluate_threshold(setting)
        end)

        # Reschedule for next check
        schedule_next_check(args)
        :ok

      {:ok, []} ->
        Logger.debug("No enabled interface thresholds, rescheduling anyway")
        schedule_next_check(args)
        :ok

      {:error, reason} ->
        Logger.error("Failed to get interface thresholds",
          reason: inspect(reason)
        )

        # Still reschedule on error
        schedule_next_check(args)
        {:error, reason}
    end
  end

  defp schedule_next_check(args) do
    case ObanSupport.safe_insert(new(args, schedule_in: @evaluation_interval_seconds)) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Interface threshold worker reschedule deferred", reason: inspect(reason))
        :ok
    end
  end

  defp get_enabled_thresholds do
    actor = SystemActor.system(:threshold_evaluator)

    InterfaceSettings
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(threshold_enabled == true)
    |> Ash.Query.filter(not is_nil(threshold_metric))
    |> Ash.Query.filter(not is_nil(threshold_comparison))
    |> Ash.Query.filter(not is_nil(threshold_value))
    |> Ash.read(actor: actor)
  end

  defp evaluate_threshold(setting) do
    # Check cooldown to avoid duplicate alerts
    cooldown_key = {__MODULE__, :last_alert, setting.device_id, setting.interface_uid}
    violation_start_key = {__MODULE__, :violation_start, setting.device_id, setting.interface_uid}

    last_alert_time =
      case :persistent_term.get(cooldown_key, nil) do
        nil -> 0
        time -> time
      end

    now = System.monotonic_time(:millisecond)

    if now - last_alert_time < @alert_cooldown_ms do
      Logger.debug("Skipping threshold check due to cooldown",
        device_id: setting.device_id,
        interface_uid: setting.interface_uid
      )
    else
      case get_latest_metric_value(setting) do
        {:ok, metric_value} when not is_nil(metric_value) ->
          if threshold_violated?(metric_value, setting.threshold_comparison, setting.threshold_value) do
            # Track when violation started for duration-based alerting
            violation_start =
              case :persistent_term.get(violation_start_key, nil) do
                nil ->
                  :persistent_term.put(violation_start_key, now)
                  now

                start_time ->
                  start_time
              end

            # Check if violation duration has been exceeded
            duration_ms = (setting.threshold_duration_seconds || 0) * 1000
            violation_duration = now - violation_start

            if violation_duration >= duration_ms do
              generate_threshold_alert(setting, metric_value, violation_duration)
              # Update cooldown and reset violation tracking
              :persistent_term.put(cooldown_key, now)
              :persistent_term.erase(violation_start_key)
            else
              Logger.debug("Threshold violated but duration not met",
                device_id: setting.device_id,
                interface_uid: setting.interface_uid,
                violation_duration_ms: violation_duration,
                required_duration_ms: duration_ms
              )
            end
          else
            # Threshold not violated - reset violation tracking
            :persistent_term.erase(violation_start_key)

            Logger.debug("Threshold not violated",
              device_id: setting.device_id,
              interface_uid: setting.interface_uid,
              metric_value: metric_value,
              threshold: setting.threshold_value,
              comparison: setting.threshold_comparison
            )
          end

        {:ok, nil} ->
          Logger.debug("No metric data available for interface",
            device_id: setting.device_id,
            interface_uid: setting.interface_uid
          )

        {:error, reason} ->
          Logger.warning("Failed to get metric value for interface",
            device_id: setting.device_id,
            interface_uid: setting.interface_uid,
            reason: inspect(reason)
          )
      end
    end
  rescue
    error ->
      Logger.error("Error evaluating threshold",
        device_id: setting.device_id,
        interface_uid: setting.interface_uid,
        error: inspect(error)
      )
  end

  defp get_latest_metric_value(setting) do
    # Map threshold_metric to actual metric names in timeseries_metrics
    metric_name = metric_name_for(setting.threshold_metric)

    # Query the latest metric value for this interface
    # This would typically query the timeseries_metrics table
    # For now, we'll use a simple Ecto query

    import Ecto.Query

    query =
      from(m in "timeseries_metrics",
        where: m.uid == ^setting.device_id,
        where: m.metric_name == ^metric_name,
        where: m.if_index == ^get_if_index(setting),
        where: m.timestamp > ago(5, "minute"),
        order_by: [desc: m.timestamp],
        limit: 1,
        select: m.value
      )

    case ServiceRadar.Repo.one(query) do
      nil -> {:ok, nil}
      value -> {:ok, value}
    end
  rescue
    error -> {:error, error}
  end

  defp get_if_index(setting) do
    # The interface_uid might contain the if_index, or we need to look it up
    # For now, try to extract from interface_uid or default to nil
    case Integer.parse(setting.interface_uid) do
      {index, _} -> index
      :error -> nil
    end
  end

  defp metric_name_for(:utilization), do: "interface_utilization"
  defp metric_name_for(:bandwidth_in), do: "interface_in_octets"
  defp metric_name_for(:bandwidth_out), do: "interface_out_octets"
  defp metric_name_for(:errors), do: "interface_errors"
  defp metric_name_for(other), do: to_string(other)

  defp threshold_violated?(value, comparison, threshold) do
    case comparison do
      :gt -> value > threshold
      :gte -> value >= threshold
      :lt -> value < threshold
      :lte -> value <= threshold
      :eq -> value == threshold
      _ -> false
    end
  end

  defp generate_threshold_alert(setting, metric_value, violation_duration_ms) do
    comparison_atom = normalize_comparison(setting.threshold_comparison)
    metric_label = metric_label_for(setting.threshold_metric)
    severity = setting.threshold_severity || :warning
    violation_duration_seconds = div(violation_duration_ms, 1000)

    Logger.info("Generating threshold violation alert",
      device_id: setting.device_id,
      interface_uid: setting.interface_uid,
      metric: setting.threshold_metric,
      value: metric_value,
      threshold: setting.threshold_value,
      comparison: comparison_atom,
      severity: severity,
      violation_duration_seconds: violation_duration_seconds
    )

    case AlertGenerator.threshold_violation(
           metric_name: "interface_#{setting.threshold_metric}",
           metric_value: metric_value,
           threshold_value: setting.threshold_value,
           comparison: comparison_atom,
           severity: severity,
           device_uid: setting.device_id,
           details: %{
             interface_uid: setting.interface_uid,
             metric_type: metric_label,
             violation_duration_seconds: violation_duration_seconds,
             threshold_config: %{
               metric: setting.threshold_metric,
               comparison: setting.threshold_comparison,
               value: setting.threshold_value,
               duration_seconds: setting.threshold_duration_seconds || 0,
               severity: severity
             }
           }
         ) do
      {:ok, alert} ->
        Logger.info("Created threshold violation alert",
          alert_id: alert.id,
          device_id: setting.device_id,
          interface_uid: setting.interface_uid
        )

      {:error, reason} ->
        Logger.error("Failed to create threshold violation alert",
          device_id: setting.device_id,
          interface_uid: setting.interface_uid,
          reason: inspect(reason)
        )
    end
  end

  defp normalize_comparison(:gt), do: :greater_than
  defp normalize_comparison(:gte), do: :greater_than
  defp normalize_comparison(:lt), do: :less_than
  defp normalize_comparison(:lte), do: :less_than
  defp normalize_comparison(:eq), do: :equals
  defp normalize_comparison(other), do: other

  defp metric_label_for(:utilization), do: "Utilization"
  defp metric_label_for(:bandwidth_in), do: "Bandwidth In"
  defp metric_label_for(:bandwidth_out), do: "Bandwidth Out"
  defp metric_label_for(:errors), do: "Errors"
  defp metric_label_for(other), do: to_string(other)
end
