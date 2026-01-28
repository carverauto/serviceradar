defmodule ServiceRadar.Inventory.InterfaceThresholdWorker do
  @moduledoc """
  Oban worker that evaluates per-metric interface threshold conditions and generates events.

  Runs periodically to check if any interface metrics exceed configured thresholds.
  When a threshold is violated, it records an OCSF event and relies on
  stateful alert rules for alert promotion.

  ## Scheduling

  This worker runs every minute and checks all interfaces with metric_thresholds configured.
  It queries the latest metric values and compares them against per-metric thresholds.

  ## Threshold Configuration

  Interface thresholds are configured in the InterfaceSettings resource:
  - metric_thresholds: per-metric map keyed by metric name
  - comparison: comparison operator (gt, lt, gte, lte, eq)
  - value: the threshold value to compare against
  - duration_seconds: how long the threshold must be exceeded

  ## Alert Generation

  When a threshold is violated, an OCSF event is recorded with:
  - metric details including interface info
  - threshold configuration metadata
  """

  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Inventory.InterfaceSettings
  alias ServiceRadar.Observability.StatefulAlertEngine
  alias ServiceRadar.SweepJobs.ObanSupport
  alias UUID

  require Logger
  require Ash.Query

  # How often to run the evaluator (1 minute)
  @evaluation_interval_seconds 60

  # Cooldown period to avoid duplicate alerts for same interface (5 minutes)
  @alert_cooldown_ms :timer.minutes(5)

  @severity_map %{
    "emergency" => OCSF.severity_fatal(),
    "critical" => OCSF.severity_critical(),
    "high" => OCSF.severity_high(),
    "warning" => OCSF.severity_medium(),
    "warn" => OCSF.severity_medium(),
    "info" => OCSF.severity_informational(),
    "informational" => OCSF.severity_informational(),
    "low" => OCSF.severity_low()
  }

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

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
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
    |> Ash.Query.filter(metric_thresholds != %{} or threshold_enabled == true)
    |> Ash.read(actor: actor)
  end

  defp evaluate_threshold(setting) do
    selected_metrics = normalize_metrics(setting.metrics_selected)
    metric_thresholds = normalize_metric_thresholds(setting.metric_thresholds)

    Enum.each(metric_thresholds, fn {metric, config} ->
      metric_name = normalize_metric_name(metric)

      if metric_selected?(metric_name, selected_metrics) and config_enabled?(config) do
        evaluate_metric_threshold(setting, metric_name, config)
      end
    end)

    maybe_evaluate_legacy_threshold(setting, selected_metrics)
  rescue
    error ->
      Logger.error("Error evaluating threshold",
        device_id: setting.device_id,
        interface_uid: setting.interface_uid,
        error: inspect(error)
      )
  end

  defp in_cooldown?(cooldown_key, now) do
    last_alert_time = :persistent_term.get(cooldown_key, 0)
    now - last_alert_time < @alert_cooldown_ms
  end

  defp log_cooldown_skip(setting, metric_name) do
    Logger.debug("Skipping threshold check due to cooldown",
      device_id: setting.device_id,
      interface_uid: setting.interface_uid,
      metric: metric_name
    )
  end

  defp evaluate_metric_threshold(setting, metric_name, config) do
    cooldown_key =
      {__MODULE__, :last_alert, setting.device_id, setting.interface_uid, metric_name}

    now = System.monotonic_time(:millisecond)

    if in_cooldown?(cooldown_key, now) do
      log_cooldown_skip(setting, metric_name)
    else
      evaluate_threshold_value(setting, metric_name, config, cooldown_key, now)
    end
  end

  defp evaluate_threshold_value(setting, metric_name, config, cooldown_key, now) do
    case get_latest_metric_value(setting, metric_name) do
      {:ok, metric_value} when not is_nil(metric_value) ->
        check_threshold(setting, metric_name, config, metric_value, cooldown_key, now)

      {:ok, nil} ->
        Logger.debug("No metric data available for interface",
          device_id: setting.device_id,
          interface_uid: setting.interface_uid,
          metric: metric_name
        )

      {:error, reason} ->
        Logger.warning("Failed to get metric value for interface",
          device_id: setting.device_id,
          interface_uid: setting.interface_uid,
          metric: metric_name,
          reason: inspect(reason)
        )
    end
  end

  defp check_threshold(setting, metric_name, config, metric_value, cooldown_key, now) do
    comparison = config_value(config, :comparison)
    threshold_type = config_value(config, :threshold_type, "absolute")
    raw_threshold = parse_number(config_value(config, :value))

    # Resolve effective threshold based on type
    {effective_threshold, if_speed_bps, utilization_pct} =
      resolve_threshold(setting, metric_name, threshold_type, raw_threshold, metric_value)

    violation_start_key =
      {__MODULE__, :violation_start, setting.device_id, setting.interface_uid, metric_name}

    if threshold_violated?(metric_value, comparison, effective_threshold) do
      # Store utilization info in config for event metadata
      enriched_config =
        config
        |> Map.put("effective_threshold", effective_threshold)
        |> Map.put("if_speed_bps", if_speed_bps)
        |> Map.put("utilization_percent", utilization_pct)

      handle_violation(
        setting,
        metric_name,
        enriched_config,
        metric_value,
        cooldown_key,
        violation_start_key,
        now
      )
    else
      clear_violation_tracking(
        setting,
        metric_name,
        violation_start_key,
        metric_value,
        comparison,
        effective_threshold
      )
    end
  end

  # Resolve threshold value, converting percentage to absolute if needed
  defp resolve_threshold(_setting, _metric_name, "absolute", threshold, _metric_value) do
    {threshold, nil, nil}
  end

  defp resolve_threshold(setting, metric_name, "percentage", threshold_pct, metric_value) do
    case get_interface_speed(setting) do
      {:ok, if_speed_bps} when is_number(if_speed_bps) and if_speed_bps > 0 ->
        # Convert interface speed from bps to bytes/sec
        max_bytes_per_sec = if_speed_bps / 8
        # Convert percentage to absolute bytes/sec threshold
        effective_threshold = max_bytes_per_sec * threshold_pct / 100
        # Calculate current utilization for event metadata
        utilization_pct =
          if is_number(metric_value) and max_bytes_per_sec > 0 do
            Float.round(metric_value / max_bytes_per_sec * 100, 1)
          else
            nil
          end

        {effective_threshold, if_speed_bps, utilization_pct}

      {:ok, _} ->
        # No valid interface speed, log warning and skip threshold evaluation
        Logger.warning("Skipping percentage threshold - no interface speed available",
          device_id: setting.device_id,
          interface_uid: setting.interface_uid,
          metric: metric_name
        )

        {nil, nil, nil}

      {:error, reason} ->
        Logger.warning("Failed to get interface speed for percentage threshold",
          device_id: setting.device_id,
          interface_uid: setting.interface_uid,
          metric: metric_name,
          reason: inspect(reason)
        )

        {nil, nil, nil}
    end
  end

  defp resolve_threshold(_setting, _metric_name, _type, threshold, _metric_value) do
    # Unknown threshold type, treat as absolute
    {threshold, nil, nil}
  end

  # Get interface speed (in bps) from the Interface resource
  defp get_interface_speed(setting) do
    import Ecto.Query

    if_index = get_if_index(setting)

    if is_nil(if_index) do
      {:error, :missing_if_index}
    else
      # Query latest interface record for speed_bps or if_speed
      query =
        from(i in "interfaces",
          where: i.device_id == ^setting.device_id,
          where: i.if_index == ^if_index,
          order_by: [desc: i.timestamp],
          limit: 1,
          select: %{speed_bps: i.speed_bps, if_speed: i.if_speed}
        )

      case ServiceRadar.Repo.one(query) do
        nil ->
          {:ok, nil}

        %{speed_bps: speed_bps} when is_number(speed_bps) and speed_bps > 0 ->
          {:ok, speed_bps}

        %{if_speed: if_speed} when is_number(if_speed) and if_speed > 0 ->
          {:ok, if_speed}

        _ ->
          {:ok, nil}
      end
    end
  rescue
    error -> {:error, error}
  end

  defp handle_violation(
         setting,
         metric_name,
         config,
         metric_value,
         cooldown_key,
         violation_start_key,
         now
       ) do
    violation_start = get_or_start_violation(violation_start_key, now)
    duration_seconds = parse_int(config_value(config, :duration_seconds, 0)) || 0
    duration_ms = duration_seconds * 1000
    violation_duration = now - violation_start

    if violation_duration >= duration_ms do
      generate_metric_event(setting, metric_name, config, metric_value, violation_duration)
      :persistent_term.put(cooldown_key, now)
      :persistent_term.erase(violation_start_key)
    else
      Logger.debug("Threshold violated but duration not met",
        device_id: setting.device_id,
        interface_uid: setting.interface_uid,
        metric: metric_name,
        violation_duration_ms: violation_duration,
        required_duration_ms: duration_ms
      )
    end
  end

  defp get_or_start_violation(violation_start_key, now) do
    case :persistent_term.get(violation_start_key, nil) do
      nil ->
        :persistent_term.put(violation_start_key, now)
        now

      start_time ->
        start_time
    end
  end

  defp clear_violation_tracking(
         setting,
         metric_name,
         violation_start_key,
         metric_value,
         comparison,
         threshold
       ) do
    :persistent_term.erase(violation_start_key)

    Logger.debug("Threshold not violated",
      device_id: setting.device_id,
      interface_uid: setting.interface_uid,
      metric: metric_name,
      metric_value: metric_value,
      threshold: threshold,
      comparison: comparison
    )
  end

  defp get_latest_metric_value(setting, metric_name) do
    if_index = get_if_index(setting)

    if is_nil(if_index) do
      {:error, :missing_if_index}
    else
      import Ecto.Query

      query =
        from(m in "timeseries_metrics",
          where: m.device_id == ^setting.device_id,
          where: m.metric_name == ^metric_name,
          where: m.if_index == ^if_index,
          where: m.timestamp > ago(5, "minute"),
          order_by: [desc: m.timestamp],
          limit: 1,
          select: m.value
        )

      case ServiceRadar.Repo.one(query) do
        nil -> {:ok, nil}
        value -> {:ok, value}
      end
    end
  rescue
    error -> {:error, error}
  end

  defp get_if_index(setting) do
    case setting.interface_uid do
      nil ->
        nil

      uid when is_integer(uid) ->
        uid

      uid when is_binary(uid) ->
        uid
        |> String.split(":")
        |> List.last()
        |> parse_int()

      _ ->
        nil
    end
  end

  defp threshold_violated?(_value, _comparison, nil), do: false

  defp threshold_violated?(value, comparison, threshold) do
    case normalize_comparison(comparison) do
      :gt -> value > threshold
      :gte -> value >= threshold
      :lt -> value < threshold
      :lte -> value <= threshold
      :eq -> value == threshold
      _ -> false
    end
  end

  defp generate_metric_event(setting, metric_name, config, metric_value, violation_duration_ms) do
    comparison = normalize_comparison(config_value(config, :comparison))
    threshold = parse_number(config_value(config, :value))
    duration_seconds = div(violation_duration_ms, 1000)

    Logger.info("Recording metric threshold event",
      device_id: setting.device_id,
      interface_uid: setting.interface_uid,
      metric: metric_name,
      value: metric_value,
      threshold: threshold,
      comparison: comparison,
      duration_seconds: duration_seconds
    )

    event = build_metric_event(setting, metric_name, config, metric_value, duration_seconds)

    case record_event(event) do
      {:ok, :skipped} ->
        :ok

      {:ok, _} ->
        _ = StatefulAlertEngine.evaluate_events([event])
        :ok

      {:error, reason} ->
        Logger.error("Failed to record metric threshold event",
          device_id: setting.device_id,
          interface_uid: setting.interface_uid,
          metric: metric_name,
          reason: inspect(reason)
        )
    end
  end

  defp record_event(event) do
    {count, _} =
      ServiceRadar.Repo.insert_all(
        "ocsf_events",
        [event],
        on_conflict: :nothing,
        returning: false
      )

    if count == 0, do: {:ok, :skipped}, else: {:ok, event}
  rescue
    error -> {:error, error}
  end

  defp build_metric_event(setting, metric_name, config, metric_value, duration_seconds) do
    event_config = config_value(config, :event, %{})
    severity_id = event_severity_id(event_config, config)
    severity = OCSF.severity_name(severity_id)
    {activity_id, class_uid, category_uid, type_uid} = event_uids(event_config)
    status_id = override_int(config_value(event_config, :status_id)) || OCSF.status_success()

    %{
      id: UUID.uuid4(),
      time: DateTime.utc_now(),
      class_uid: class_uid,
      category_uid: category_uid,
      type_uid: type_uid,
      activity_id: activity_id,
      activity_name: activity_name_for(class_uid, activity_id),
      severity_id: severity_id,
      severity: severity,
      message: event_message(event_config, metric_name, metric_value, config),
      status_id: status_id,
      status: config_value(event_config, :status) || OCSF.status_name(status_id),
      status_code: config_value(event_config, :status_code),
      status_detail: config_value(event_config, :status_detail),
      metadata:
        build_metric_metadata(setting, metric_name, config, metric_value, duration_seconds),
      actor:
        OCSF.build_actor(app_name: "serviceradar.core", process: "interface_threshold_worker"),
      device: OCSF.build_device(uid: setting.device_id),
      log_name: config_value(event_config, :log_name) || "metrics.interface",
      log_provider: config_value(event_config, :log_provider) || "snmp",
      log_level: log_level_for_severity(severity_id),
      unmapped:
        build_metric_unmapped(setting, metric_name, config, metric_value, duration_seconds),
      created_at: DateTime.utc_now()
    }
  end

  defp build_metric_metadata(setting, metric_name, config, metric_value, duration_seconds) do
    comparison = normalize_comparison(config_value(config, :comparison))
    threshold = parse_number(config_value(config, :value))
    threshold_type = config_value(config, :threshold_type, "absolute")

    # Include utilization-related fields if available
    utilization_fields =
      if threshold_type == "percentage" do
        %{
          "threshold_type" => threshold_type,
          "threshold_percent" => threshold,
          "effective_threshold_bytes_per_sec" => config_value(config, :effective_threshold),
          "if_speed_bps" => config_value(config, :if_speed_bps),
          "utilization_percent" => config_value(config, :utilization_percent)
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
      else
        %{"threshold_type" => threshold_type}
      end

    OCSF.build_metadata(
      version: "1.7.0",
      product_name: "ServiceRadar Core",
      correlation_uid:
        "metric_threshold:#{setting.device_id}:#{setting.interface_uid}:#{metric_name}:#{System.unique_integer([:positive])}"
    )
    |> Map.put(
      "serviceradar",
      %{
        "source" => "metric",
        "device_id" => setting.device_id,
        "interface_uid" => setting.interface_uid,
        "metric" => metric_name,
        "comparison" => to_string(comparison),
        "threshold_value" => threshold,
        "metric_value" => metric_value,
        "duration_seconds" => duration_seconds
      }
      |> Map.merge(utilization_fields)
    )
  end

  defp build_metric_unmapped(setting, metric_name, config, metric_value, duration_seconds) do
    threshold_type = config_value(config, :threshold_type, "absolute")

    base = %{
      "device_id" => setting.device_id,
      "interface_uid" => setting.interface_uid,
      "metric" => metric_name,
      "comparison" => to_string(normalize_comparison(config_value(config, :comparison))),
      "threshold_value" => parse_number(config_value(config, :value)),
      "threshold_type" => threshold_type,
      "metric_value" => metric_value,
      "duration_seconds" => duration_seconds,
      "event_config" => config_value(config, :event, %{})
    }

    # Add utilization fields if percentage threshold
    if threshold_type == "percentage" do
      Map.merge(base, %{
        "effective_threshold_bytes_per_sec" => config_value(config, :effective_threshold),
        "if_speed_bps" => config_value(config, :if_speed_bps),
        "utilization_percent" => config_value(config, :utilization_percent)
      })
    else
      base
    end
  end

  defp event_severity_id(event_config, config) do
    cond do
      is_number(event_config["severity_id"]) ->
        event_config["severity_id"]

      is_number(event_config[:severity_id]) ->
        event_config[:severity_id]

      is_binary(event_config["severity"]) ->
        severity_from_text(event_config["severity"])

      is_atom(event_config[:severity]) ->
        severity_from_text(to_string(event_config[:severity]))

      true ->
        severity_from_text(to_string(config_value(config, :severity, "warning")))
    end
  end

  defp severity_from_text(text) when is_binary(text) do
    text
    |> String.downcase()
    |> Map.get(@severity_map, OCSF.severity_unknown())
  end

  defp event_uids(event_config) do
    activity_id =
      override_int(config_value(event_config, :activity_id)) || OCSF.activity_network_traffic()

    class_uid =
      override_int(config_value(event_config, :class_uid)) || OCSF.class_network_activity()

    category_uid =
      override_int(config_value(event_config, :category_uid)) || OCSF.category_network_activity()

    type_uid =
      override_int(config_value(event_config, :type_uid)) || OCSF.type_uid(class_uid, activity_id)

    {activity_id, class_uid, category_uid, type_uid}
  end

  defp activity_name_for(class_uid, activity_id) do
    if class_uid == OCSF.class_network_activity() do
      OCSF.network_activity_name(activity_id)
    else
      OCSF.log_activity_name(activity_id)
    end
  end

  defp event_message(event_config, metric_name, metric_value, config) do
    case config_value(event_config, :message) do
      nil ->
        default_event_message(metric_name, metric_value, config)

      custom_message ->
        custom_message
    end
  end

  defp default_event_message(metric_name, metric_value, config) do
    threshold_type = config_value(config, :threshold_type, "absolute")

    if threshold_type == "percentage" do
      percentage_message(metric_name, metric_value, config)
    else
      "Metric #{metric_name} threshold violated (value=#{metric_value}, threshold=#{config_value(config, :value)})"
    end
  end

  defp percentage_message(metric_name, metric_value, config) do
    utilization_pct = config_value(config, :utilization_percent)
    threshold_pct = config_value(config, :value)

    if utilization_pct do
      "Interface utilization at #{utilization_pct}% exceeds #{threshold_pct}% threshold (#{metric_name})"
    else
      "Metric #{metric_name} exceeds #{threshold_pct}% threshold (value=#{metric_value})"
    end
  end

  defp log_level_for_severity(severity_id) do
    cond do
      severity_id >= OCSF.severity_fatal() -> "fatal"
      severity_id >= OCSF.severity_critical() -> "critical"
      severity_id >= OCSF.severity_high() -> "high"
      severity_id >= OCSF.severity_medium() -> "warning"
      severity_id >= OCSF.severity_informational() -> "info"
      true -> "unknown"
    end
  end

  defp override_int(value) when is_integer(value), do: value

  defp override_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp override_int(_), do: nil

  defp normalize_metrics(metrics) when is_list(metrics) do
    Enum.map(metrics, &normalize_metric_name/1)
  end

  defp normalize_metrics(_), do: []

  defp normalize_metric_thresholds(metrics) when is_map(metrics) do
    metrics
    |> Enum.map(fn {metric, config} -> {normalize_metric_name(metric), config} end)
    |> Map.new()
  end

  defp normalize_metric_thresholds(_), do: %{}

  defp normalize_metric_name(metric) when is_atom(metric), do: Atom.to_string(metric)
  defp normalize_metric_name(metric) when is_binary(metric), do: metric
  defp normalize_metric_name(metric), do: to_string(metric)

  defp metric_selected?(metric_name, selected_metrics) do
    metric_name in selected_metrics
  end

  defp config_enabled?(config) when is_map(config) do
    enabled = config_value(config, :enabled, true)
    comparison = blank_to_nil(config_value(config, :comparison))
    value = config_value(config, :value)
    enabled && not is_nil(comparison) && not is_nil(value)
  end

  defp config_enabled?(_), do: false

  defp maybe_evaluate_legacy_threshold(setting, selected_metrics) do
    if setting.threshold_enabled && setting.threshold_metric && setting.threshold_comparison &&
         not is_nil(setting.threshold_value) do
      metric_name = legacy_metric_name_for(setting.threshold_metric)

      if metric_name && metric_selected?(metric_name, selected_metrics) do
        config = %{
          "enabled" => true,
          "comparison" => setting.threshold_comparison,
          "value" => setting.threshold_value,
          "duration_seconds" => setting.threshold_duration_seconds,
          "severity" => setting.threshold_severity
        }

        evaluate_metric_threshold(setting, metric_name, config)
      end
    end
  end

  defp legacy_metric_name_for(:bandwidth_in), do: "ifInOctets"
  defp legacy_metric_name_for(:bandwidth_out), do: "ifOutOctets"
  defp legacy_metric_name_for(:errors), do: "ifInErrors"
  defp legacy_metric_name_for(:utilization), do: "ifInOctets"
  defp legacy_metric_name_for(other), do: to_string(other)

  defp normalize_comparison(comparison) when is_binary(comparison) do
    case String.downcase(comparison) do
      "gt" -> :gt
      "gte" -> :gte
      "lt" -> :lt
      "lte" -> :lte
      "eq" -> :eq
      _ -> nil
    end
  end

  defp normalize_comparison(comparison) when is_atom(comparison), do: comparison
  defp normalize_comparison(_), do: nil

  defp parse_number(value) when is_integer(value), do: value
  defp parse_number(value) when is_float(value), do: value

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> nil
    end
  end

  defp parse_number(_), do: nil

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp config_value(config, key, default \\ nil) when is_map(config) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key)) || default
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
