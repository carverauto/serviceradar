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

  ## Evaluation State

  Each run reads the per-metric violation start and last alert time from
  `platform.interface_threshold_states` and writes back only what changed, so
  the duration and cooldown checks hold across nodes and restarts. A metric
  that alerted is skipped for the cooldown period that follows.

  ## Alert Generation

  When a threshold is violated, an OCSF event is recorded with:
  - metric details including interface info
  - threshold configuration metadata

  Events are published through `ServiceRadar.Events.OcsfEventPublisher`:
  EventWriter stores them in the active telemetry backend, loads the
  warehouse in batches and applies stateful alert rules once per event.
  """

  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Events.OcsfEventPublisher
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Inventory.InterfaceSettings
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  # How often to run the evaluator (1 minute)
  @evaluation_interval_seconds 60

  # Cooldown period to avoid duplicate alerts for same interface (5 minutes)
  @alert_cooldown_ms to_timeout(minute: 5)

  @state_table "interface_threshold_states"
  @state_prefix "platform"
  @state_write_batch 1_000
  @idle_state %{violation_started_at: nil, last_alert_at: nil}

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
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^Oban.Worker.to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Logger.info("Running interface threshold evaluation")

    result = run()

    # Reschedule even when this run failed, so evaluation resumes next interval.
    schedule_next_check(args)
    result
  end

  @doc """
  Evaluates every enabled interface threshold once, without rescheduling.

  Options:

    * `:now` - the wall-clock time the duration and cooldown checks use;
      defaults to `DateTime.utc_now/0` (tests)
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, settings} <- get_enabled_thresholds(),
         {:ok, states} <- load_states() do
      log_evaluation_start(settings)

      settings
      |> evaluate_settings(states, now)
      |> persist_states(states, now)
    else
      {:error, reason} = error ->
        Logger.error("Failed to evaluate interface thresholds", reason: inspect(reason))
        error
    end
  end

  defp log_evaluation_start([]), do: Logger.debug("No enabled interface thresholds")

  defp log_evaluation_start(settings),
    do: Logger.info("Evaluating #{length(settings)} interface thresholds")

  defp schedule_next_check(args) do
    case ObanSupport.safe_insert(
           SelfScheduling.successor_changeset(__MODULE__, args, @evaluation_interval_seconds)
         ) do
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

  # Threads every configured {setting, metric} through its persisted state and
  # returns the state each one holds after this run. A metric configured twice
  # on one interface (a legacy threshold on a metric that also has a per-metric
  # threshold) shares one state, evaluated in order, as before.
  defp evaluate_settings(settings, states, now) do
    Enum.reduce(settings, %{}, fn setting, acc ->
      setting
      |> threshold_checks()
      |> Enum.reduce(acc, fn {metric_name, config}, acc ->
        key = {setting.id, metric_name}
        state = Map.get(acc, key) || Map.get(states, key, @idle_state)
        Map.put(acc, key, evaluate_metric_threshold(setting, metric_name, config, state, now))
      end)
    end)
  end

  defp threshold_checks(setting) do
    selected_metrics = normalize_metrics(setting.metrics_selected)

    metric_checks =
      setting.metric_thresholds
      |> normalize_metric_thresholds()
      |> Enum.filter(fn {metric_name, config} ->
        metric_selected?(metric_name, selected_metrics) and config_enabled?(config)
      end)

    metric_checks ++ legacy_threshold_checks(setting, selected_metrics)
  end

  defp in_cooldown?(%{last_alert_at: %DateTime{} = last_alert_at}, now),
    do: DateTime.diff(now, last_alert_at, :millisecond) < @alert_cooldown_ms

  defp in_cooldown?(_state, _now), do: false

  defp log_cooldown_skip(setting, metric_name) do
    Logger.debug("Skipping threshold check due to cooldown",
      device_id: setting.device_id,
      interface_uid: setting.interface_uid,
      metric: metric_name
    )
  end

  defp evaluate_metric_threshold(setting, metric_name, config, state, now) do
    if in_cooldown?(state, now) do
      log_cooldown_skip(setting, metric_name)
      state
    else
      evaluate_threshold_value(setting, metric_name, config, state, now)
    end
  rescue
    error ->
      Logger.error("Error evaluating threshold",
        device_id: setting.device_id,
        interface_uid: setting.interface_uid,
        metric: metric_name,
        error: inspect(error)
      )

      state
  end

  defp evaluate_threshold_value(setting, metric_name, config, state, now) do
    case get_latest_metric_value(setting, metric_name) do
      {:ok, metric_value} when not is_nil(metric_value) ->
        check_threshold(setting, metric_name, config, metric_value, state, now)

      {:ok, nil} ->
        Logger.debug("No metric data available for interface",
          device_id: setting.device_id,
          interface_uid: setting.interface_uid,
          metric: metric_name
        )

        state

      {:error, reason} ->
        Logger.warning("Failed to get metric value for interface",
          device_id: setting.device_id,
          interface_uid: setting.interface_uid,
          metric: metric_name,
          reason: inspect(reason)
        )

        state
    end
  end

  defp check_threshold(setting, metric_name, config, metric_value, state, now) do
    comparison = config_value(config, :comparison)
    threshold_type = config_value(config, :threshold_type, "absolute")
    raw_threshold = parse_number(config_value(config, :value))

    # Resolve effective threshold based on type
    {effective_threshold, if_speed_bps, utilization_pct} =
      resolve_threshold(setting, metric_name, threshold_type, raw_threshold, metric_value)

    if threshold_violated?(metric_value, comparison, effective_threshold) do
      # Store utilization info in config for event metadata
      enriched_config =
        config
        |> Map.put("effective_threshold", effective_threshold)
        |> Map.put("if_speed_bps", if_speed_bps)
        |> Map.put("utilization_percent", utilization_pct)

      handle_violation(setting, metric_name, enriched_config, metric_value, state, now)
    else
      clear_violation_tracking(
        setting,
        metric_name,
        state,
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

      case Repo.one(query) do
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

  defp handle_violation(setting, metric_name, config, metric_value, state, now) do
    violation_started_at = state.violation_started_at || now
    duration_seconds = parse_int(config_value(config, :duration_seconds, 0)) || 0
    duration_ms = duration_seconds * 1000
    violation_duration = DateTime.diff(now, violation_started_at, :millisecond)

    if violation_duration >= duration_ms do
      generate_metric_event(setting, metric_name, config, metric_value, violation_duration)
      %{violation_started_at: nil, last_alert_at: now}
    else
      Logger.debug("Threshold violated but duration not met",
        device_id: setting.device_id,
        interface_uid: setting.interface_uid,
        metric: metric_name,
        violation_duration_ms: violation_duration,
        required_duration_ms: duration_ms
      )

      %{state | violation_started_at: violation_started_at}
    end
  end

  defp clear_violation_tracking(setting, metric_name, state, metric_value, comparison, threshold) do
    Logger.debug("Threshold not violated",
      device_id: setting.device_id,
      interface_uid: setting.interface_uid,
      metric: metric_name,
      metric_value: metric_value,
      threshold: threshold,
      comparison: comparison
    )

    %{state | violation_started_at: nil}
  end

  # Evaluation state lives in `platform.interface_threshold_states`, one row per
  # {interface setting, metric} that is violating or inside its alert cooldown,
  # so it is shared by every node that runs this job and survives restarts. A
  # row whose metric is neither is deleted, as is the row of a metric no longer
  # configured; deleting the interface setting cascades to its rows.
  #
  # The times are wall-clock UTC rather than monotonic: monotonic time is
  # node-local and usually negative, so it can neither be compared across
  # nodes nor seeded with 0 to mean "never".
  defp load_states do
    query =
      from(s in @state_table,
        select:
          {type(s.interface_settings_id, Ecto.UUID), s.metric_name,
           type(s.violation_started_at, :utc_datetime_usec),
           type(s.last_alert_at, :utc_datetime_usec)}
      )

    states =
      query
      |> Repo.all(prefix: @state_prefix)
      |> Map.new(fn {setting_id, metric_name, violation_started_at, last_alert_at} ->
        {{setting_id, metric_name},
         %{violation_started_at: violation_started_at, last_alert_at: last_alert_at}}
      end)

    {:ok, states}
  rescue
    error -> {:error, error}
  end

  defp persist_states(new_states, old_states, now) do
    live = Map.reject(new_states, fn {_key, state} -> idle?(state, now) end)
    stale = old_states |> Map.keys() |> Enum.reject(&Map.has_key?(live, &1))
    changed = Enum.reject(live, fn {key, state} -> Map.get(old_states, key) == state end)

    delete_states(stale)
    upsert_states(changed, now)
    :ok
  rescue
    error ->
      Logger.error("Failed to persist interface threshold state", error: inspect(error))
      {:error, error}
  end

  defp idle?(%{violation_started_at: nil} = state, now), do: not in_cooldown?(state, now)
  defp idle?(_state, _now), do: false

  defp delete_states(keys) do
    keys
    |> Enum.chunk_every(@state_write_batch)
    |> Enum.each(fn chunk ->
      setting_ids = Enum.map(chunk, fn {setting_id, _metric} -> Ecto.UUID.dump!(setting_id) end)
      metric_names = Enum.map(chunk, fn {_setting_id, metric_name} -> metric_name end)

      query =
        from(s in @state_table,
          where:
            fragment(
              "(?, ?) IN (SELECT * FROM unnest(CAST(? AS uuid[]), CAST(? AS text[])))",
              s.interface_settings_id,
              s.metric_name,
              ^setting_ids,
              ^metric_names
            )
        )

      Repo.delete_all(query, prefix: @state_prefix)
    end)
  end

  defp upsert_states(entries, now) do
    entries
    |> Enum.map(fn {{setting_id, metric_name}, state} ->
      %{
        interface_settings_id: Ecto.UUID.dump!(setting_id),
        metric_name: metric_name,
        violation_started_at: state.violation_started_at,
        last_alert_at: state.last_alert_at,
        updated_at: now
      }
    end)
    |> Enum.chunk_every(@state_write_batch)
    |> Enum.each(fn rows ->
      Repo.insert_all(@state_table, rows,
        prefix: @state_prefix,
        on_conflict: {:replace, [:violation_started_at, :last_alert_at, :updated_at]},
        conflict_target: [:interface_settings_id, :metric_name]
      )
    end)
  end

  defp get_latest_metric_value(setting, metric_name) do
    if_index = get_if_index(setting)

    if is_nil(if_index) do
      {:error, :missing_if_index}
    else
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

      case Repo.one(query) do
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

    case OcsfEventPublisher.publish(event, family: :inventory) do
      {:ok, _event} ->
        :ok

      {:error, :suppressed} ->
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

  defp build_metric_event(setting, metric_name, config, metric_value, duration_seconds) do
    event_config = config_value(config, :event, %{})
    severity_id = event_severity_id(event_config, config)
    severity = OCSF.severity_name(severity_id)
    {activity_id, class_uid, category_uid, type_uid} = event_uids(event_config)
    status_id = override_int(config_value(event_config, :status_id)) || OCSF.status_success()

    %{
      id: Ecto.UUID.bingenerate(),
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

    [
      product_name: "ServiceRadar Core",
      correlation_uid:
        "metric_threshold:#{setting.device_id}:#{setting.interface_uid}:#{metric_name}:#{System.unique_integer([:positive])}"
    ]
    |> OCSF.build_metadata()
    |> Map.put(
      "serviceradar",
      Map.merge(
        %{
          "source" => "metric",
          "device_id" => setting.device_id,
          "interface_uid" => setting.interface_uid,
          "metric" => metric_name,
          "comparison" => to_string(comparison),
          "threshold_value" => threshold,
          "metric_value" => metric_value,
          "duration_seconds" => duration_seconds
        },
        utilization_fields
      )
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
    Map.get(@severity_map, String.downcase(text), OCSF.severity_unknown())
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
    Map.new(metrics, fn {metric, config} -> {normalize_metric_name(metric), config} end)
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

  defp legacy_threshold_checks(setting, selected_metrics) do
    if setting.threshold_enabled && setting.threshold_metric && setting.threshold_comparison &&
         not is_nil(setting.threshold_value) do
      metric_name = legacy_metric_name_for(setting.threshold_metric)

      if metric_selected?(metric_name, selected_metrics) do
        config = %{
          "enabled" => true,
          "comparison" => setting.threshold_comparison,
          "value" => setting.threshold_value,
          "duration_seconds" => setting.threshold_duration_seconds,
          "severity" => setting.threshold_severity
        }

        [{metric_name, config}]
      else
        []
      end
    else
      []
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
