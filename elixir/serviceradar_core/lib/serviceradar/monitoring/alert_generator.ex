defmodule ServiceRadar.Monitoring.AlertGenerator do
  @moduledoc """
  Alert generation service for ServiceRadar monitoring events.

  Creates alerts from various monitoring events:
  - Service state changes (up/down)
  - Device availability changes
  - Gateway/agent health issues
  - Metric threshold violations
  - Stats anomalies

  ## Usage

      # Generate alert for service down
      AlertGenerator.service_down(
        service_check_id: "check-123",
        service_name: "web-server",
        gateway_id: "gateway-1",
        device_uid: "device-456",
        details: %{"error" => "Connection refused"}
      )

      # Generate alert for device offline
      AlertGenerator.device_offline(
        device_uid: "device-456",
        last_seen_at: ~U[2025-01-01 12:00:00Z],
        details: %{"ip" => "192.168.1.100"}
      )

  ## Notification

  Every function here does exactly one thing: it writes an `Alert` row. It sends
  nothing, and it enqueues nothing.

  The alert row IS the notification request. An alert created here has
  `notification_count == 0`, which is precisely what `Alert.:needs_notification`
  selects, so the `:send_notifications` AshOban trigger picks it up on the next
  tick and runs `Alert.:send_notification` - the action that emits the `:fire`
  routing request into `ServiceRadar.Notifications`. That scan is the
  first-notification safety net design D8 sanctions for the alert-creation paths
  that do not go through `AlertLifecycle` (`LogPromotion` and `TrivyReports` are
  the two in tree), and it is why this module must NOT enqueue a routing request
  of its own: D8 reserves originating a new incident notification for
  `AlertLifecycle`, and a second emission from here would race it.

  This module used to call `ServiceRadar.Monitoring.WebhookNotifier` after each
  create. Nothing supervised that GenServer, so every one of those calls took the
  `{:error, :not_running}` branch and delivered nothing; the module is gone.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Observability.EventTitle

  require Logger

  @stats_alert_cooldown to_timeout(minute: 5)

  # State for tracking stats alerts (simple module attribute for now)
  # In production, use ETS or GenServer for proper state management
  @doc false
  def get_last_stats_alert do
    :persistent_term.get({__MODULE__, :last_stats_alert}, {0, DateTime.from_unix!(0)})
  rescue
    _ -> {0, DateTime.from_unix!(0)}
  end

  @doc false
  def set_last_stats_alert(count, time) do
    :persistent_term.put({__MODULE__, :last_stats_alert}, {count, time})
  rescue
    _ -> :ok
  end

  @doc """
  Generate alert for a service going down.

  ## Options

  - `:service_check_id` - Service check ID (required)
  - `:service_name` - Name of the service
  - `:gateway_id` - Gateway that detected the outage
  - `:device_uid` - Device the service runs on
  - `:agent_uid` - Agent managing the gateway
  - `:error` - Error message/details
  - `:details` - Additional details map
  """
  @spec service_down(keyword()) :: {:ok, Alert.t()} | {:error, term()}
  def service_down(opts) do
    service_name = Keyword.get(opts, :service_name, "Unknown Service")

    attrs = %{
      title: "Service Down: #{service_name}",
      description: "Service #{service_name} is not responding",
      severity: :critical,
      source_type: :service_check,
      source_id: Keyword.get(opts, :service_check_id),
      service_check_id: Keyword.get(opts, :service_check_id),
      device_uid: Keyword.get(opts, :device_uid),
      agent_uid: Keyword.get(opts, :agent_uid),
      metadata: build_metadata(opts)
    }

    create_alert(attrs, opts)
  end

  @doc """
  Generate alert for a service recovering.
  """
  @spec service_recovered(keyword()) :: {:ok, Alert.t()} | {:error, term()}
  def service_recovered(opts) do
    service_name = Keyword.get(opts, :service_name, "Unknown Service")

    attrs = %{
      title: "Service Recovered: #{service_name}",
      description: "Service #{service_name} is now responding",
      severity: :info,
      source_type: :service_check,
      source_id: Keyword.get(opts, :service_check_id),
      service_check_id: Keyword.get(opts, :service_check_id),
      device_uid: Keyword.get(opts, :device_uid),
      agent_uid: Keyword.get(opts, :agent_uid),
      metadata: build_metadata(opts)
    }

    create_alert(attrs, opts)
  end

  @doc """
  Generate alert for a device going offline.

  ## Options

  - `:device_uid` - Device UID (required)
  - `:last_seen_at` - When the device was last seen
  - `:ip` - Device IP address
  - `:details` - Additional details
  """
  @spec device_offline(keyword()) :: {:ok, Alert.t()} | {:error, term()}
  def device_offline(opts) do
    device_uid = Keyword.fetch!(opts, :device_uid)

    attrs = %{
      title: "Device Offline",
      description: "Device #{device_uid} is not responding",
      severity: :warning,
      source_type: :device,
      source_id: device_uid,
      device_uid: device_uid,
      metadata: build_metadata(opts)
    }

    create_alert(attrs, opts)
  end

  @doc """
  Generate alert for a gateway going offline.

  ## Options

  - `:gateway_id` - Gateway ID (required)
  - `:agent_uid` - Agent UID
  - `:partition` - Partition the gateway belongs to
  """
  @spec gateway_offline(keyword()) :: {:ok, Alert.t()} | {:error, term()}
  def gateway_offline(opts) do
    gateway_id = Keyword.fetch!(opts, :gateway_id)

    attrs = %{
      title: "Node Offline",
      description: "Gateway #{gateway_id} is not responding",
      severity: :critical,
      source_type: :gateway,
      source_id: gateway_id,
      agent_uid: Keyword.get(opts, :agent_uid),
      metadata: build_metadata(opts)
    }

    create_alert(attrs, opts)
  end

  @doc """
  Generate alert for a gateway recovery.
  """
  @spec gateway_recovered(keyword()) :: {:ok, Alert.t()} | {:error, term()}
  def gateway_recovered(opts) do
    gateway_id = Keyword.fetch!(opts, :gateway_id)

    attrs = %{
      title: "Node Online",
      description: "Gateway #{gateway_id} is now responding",
      severity: :info,
      source_type: :gateway,
      source_id: gateway_id,
      agent_uid: Keyword.get(opts, :agent_uid),
      metadata: build_metadata(opts)
    }

    create_alert(attrs, opts)
  end

  @doc """
  Generate alert for an agent going offline.
  """
  @spec agent_offline(keyword()) :: {:ok, Alert.t()} | {:error, term()}
  def agent_offline(opts) do
    agent_uid = Keyword.fetch!(opts, :agent_uid)

    attrs = %{
      title: "Agent Offline",
      description: "Agent #{agent_uid} is not responding",
      severity: :critical,
      source_type: :agent,
      source_id: agent_uid,
      agent_uid: agent_uid,
      metadata: build_metadata(opts)
    }

    create_alert(attrs, opts)
  end

  @doc """
  Generate alert for a metric threshold violation.

  ## Options

  - `:metric_name` - Name of the metric (required)
  - `:metric_value` - Current value (required)
  - `:threshold_value` - Threshold that was violated (required)
  - `:comparison` - How value compared (:greater_than, :less_than, etc.)
  - `:device_uid` - Device the metric belongs to
  """
  @spec threshold_violation(keyword()) :: {:ok, Alert.t()} | {:error, term()}
  def threshold_violation(opts) do
    metric_name = Keyword.fetch!(opts, :metric_name)
    metric_value = Keyword.fetch!(opts, :metric_value)
    threshold = Keyword.fetch!(opts, :threshold_value)
    comparison = Keyword.get(opts, :comparison, :greater_than)

    comparison_text =
      case comparison do
        :greater_than -> "exceeded"
        :less_than -> "fell below"
        :equals -> "equals"
        _ -> "violated"
      end

    attrs = %{
      title: "Threshold Violation: #{metric_name}",
      description: "#{metric_name} #{comparison_text} threshold: #{metric_value} vs #{threshold}",
      severity: Keyword.get(opts, :severity, :warning),
      source_type: :device,
      source_id: Keyword.get(opts, :device_uid),
      device_uid: Keyword.get(opts, :device_uid),
      metric_name: metric_name,
      metric_value: metric_value,
      threshold_value: threshold,
      comparison: comparison,
      metadata: build_metadata(opts)
    }

    create_alert(attrs, opts)
  end

  @doc """
  Generate an alert from an OCSF event.

  Options:
    - `:alert` - map of overrides (title, description, severity, metadata)
    - `:actor` - Ash actor to use for policy checks (optional)
    - `:device_uid` - canonical `ocsf_devices.uid` this alert is about, or nil

  ## `:device_uid` must already be canonical

  `alerts.device_uid` carries a foreign key to `ocsf_devices(uid)`, so a value
  that is not a real device uid does not produce a mislabelled alert — it fails
  the insert and the alert is **lost**. The three callers degrade differently and
  all of them degrade quietly, so this is worth being blunt about: trivy logs and
  drops, log promotion counts it as attempted-not-created, and the stateful
  engine returns an error the state machine only logs — dropping the snapshot's
  `alert_id` so the rule re-fires forever.

  Trading "an alert with no device" for "no alert" is a bad trade. Callers pass
  the output of `DeviceCorrelation.resolve/1` (canonical uid, or nil) and never a
  raw hostname, IP, or record field.

  Populating this is not only a labelling change. It activates two systems that
  are dormant while the column is NULL: the create-time out-of-service gate on
  the `:trigger` action, and `:device_out_of_service`, the highest-precedence
  notification suppression reason. `alert.device_uid` is also a routable match
  field, so routes and silences written against it begin matching. See the
  `add-alert-device-identity` OpenSpec change.
  """
  @spec from_event(map(), keyword()) :: {:ok, Alert.t() | :skipped} | {:error, term()}
  def from_event(event, opts \\ []) when is_map(event) do
    alert_config = Keyword.get(opts, :alert, %{})

    if alert_disabled?(alert_config) do
      {:ok, :skipped}
    else
      severity = alert_severity(event, alert_config)
      title = override_string(alert_config, "title") || EventTitle.event_title(event)
      description = override_string(alert_config, "description") || Map.get(event, :message)

      attrs = %{
        title: title,
        description: description,
        severity: severity,
        source_type: :event,
        source_id: event_id_string(event),
        event_id: event_id_string(event),
        event_time: Map.get(event, :time),
        # Deliberately NOT sniffed from the event. `event.device[:uid]` is a
        # hostname or IP whenever correlation failed upstream, and writing that
        # here violates the FK and loses the alert. The caller resolved it or it
        # stays nil.
        device_uid: opts |> Keyword.get(:device_uid) |> normalize_device_uid(),
        metadata: event_alert_metadata(event, alert_config)
      }

      create_alert(attrs, opts)
    end
  end

  @doc """
  Normalise a caller-supplied device uid to a value safe for `alerts.device_uid`.

  Only a non-empty binary survives. An empty or whitespace-only string is not a
  uid, and because the column carries a foreign key to `ocsf_devices(uid)` it
  would fail the insert exactly as a hostname does — losing the alert rather
  than mislabelling it.

  This normalises; it does not verify. Passing a syntactically fine but
  non-existent uid still violates the FK, which is why callers pass the output
  of `DeviceCorrelation.resolve/1` and never a raw record field.
  """
  @spec normalize_device_uid(term()) :: String.t() | nil
  def normalize_device_uid(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_device_uid(_value), do: nil

  @doc """
  Handle stats anomaly alert (non-canonical devices filtered).

  Port of Go's handleStatsAnomaly function.

  The in-module cooldown above is retained deliberately: it is a guard on alert
  CREATION, not on delivery. Without it a rising `skipped_non_canonical` count
  would write a new alert row on every aggregation cycle. Notification cadence
  for the rows it does write belongs to the notification platform
  (route `throttle_seconds`, rule `cooldown_seconds`, `renotify_seconds`), not
  here.
  """
  @spec stats_anomaly(map(), keyword()) :: :ok | {:error, term()}
  def stats_anomaly(meta, opts \\ []) do
    skipped = meta[:skipped_non_canonical] || meta["skipped_non_canonical"] || 0

    # Check cooldown
    {last_count, last_time} = get_last_stats_alert()
    now = DateTime.utc_now()

    if skip_stats_alert?(skipped, last_count, last_time, now) do
      :ok
    else
      set_last_stats_alert(skipped, now)
      maybe_create_stats_alert(meta, skipped, last_count, opts)
    end
  end

  defp skip_stats_alert?(skipped, last_count, last_time, now) do
    skipped <= last_count and
      DateTime.diff(now, last_time, :millisecond) < @stats_alert_cooldown
  end

  defp maybe_create_stats_alert(meta, skipped, last_count, opts) do
    delta = skipped - last_count

    if delta > 0 do
      case create_alert(stats_alert_attrs(meta, skipped, delta), opts) do
        {:ok, _alert} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp stats_alert_attrs(meta, skipped, delta) do
    %{
      title: "Non-canonical devices filtered from stats",
      description:
        "Stats aggregator filtered #{delta} newly detected non-canonical devices " <>
          "(total filtered: #{skipped}).",
      severity: :warning,
      source_type: :system,
      source_id: "stats-aggregator",
      metadata: build_stats_alert_details(meta, skipped, delta)
    }
  end

  defp build_stats_alert_details(meta, skipped, delta) do
    %{
      "raw_records" => meta[:raw_records] || meta["raw_records"],
      "processed_records" => meta[:processed_records] || meta["processed_records"],
      "skipped_non_canonical" => skipped,
      "delta_non_canonical" => delta,
      "inferred_canonical_fallback" =>
        meta[:inferred_canonical_fallback] || meta["inferred_canonical_fallback"],
      "skipped_service_components" =>
        meta[:skipped_service_components] || meta["skipped_service_components"],
      "skipped_tombstoned" =>
        meta[:skipped_tombstoned_records] || meta["skipped_tombstoned_records"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Private functions

  # Writing the row is the whole job: the row IS the notification request. See
  # the "Notification" section of the moduledoc for why nothing is enqueued here.
  #
  # Live tails learn about the new row through
  # `ServiceRadar.Monitoring.AlertNotifier`, which fires on every Alert create
  # (including writers that bypass this module, like the camera alert router),
  # so nothing is broadcast here.
  defp create_alert(attrs, opts) do
    # DB connection's search_path determines the schema
    actor = Keyword.get(opts, :actor) || SystemActor.system(:alert_generator)

    # Create the alert in the database
    with {:error, error} <-
           Alert
           |> Ash.Changeset.for_create(:trigger, attrs, actor: actor)
           |> Ash.create() do
      Logger.error("Failed to create alert: #{inspect(error)}")
      {:error, error}
    end
  end

  defp build_metadata(opts) do
    details = Keyword.get(opts, :details, %{})

    base_metadata =
      %{}
      |> maybe_put("gateway_id", Keyword.get(opts, :gateway_id))
      |> maybe_put("partition", Keyword.get(opts, :partition))
      |> maybe_put("ip", Keyword.get(opts, :ip))
      |> maybe_put("error", Keyword.get(opts, :error))
      |> maybe_put("last_seen_at", format_datetime(Keyword.get(opts, :last_seen_at)))

    Map.merge(base_metadata, details)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, to_string(value))

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(other), do: to_string(other)

  defp alert_disabled?(false), do: true
  defp alert_disabled?(%{"enabled" => false}), do: true
  defp alert_disabled?(_), do: false

  defp alert_severity(event, alert_config) do
    override =
      override_string(alert_config, "severity") ||
        override_atom(alert_config, "severity")

    case override do
      nil -> severity_from_event(event)
      value -> normalize_severity(value)
    end
  end

  defp severity_from_event(event) do
    case Map.get(event, :severity_id) do
      id when is_number(id) -> severity_for_id(id)
      _ -> :warning
    end
  end

  defp severity_for_id(id) when id >= 6, do: :emergency
  defp severity_for_id(id) when id >= 5, do: :critical
  defp severity_for_id(id) when id >= 4, do: :critical
  defp severity_for_id(id) when id >= 3, do: :warning
  defp severity_for_id(id) when id >= 1, do: :info
  defp severity_for_id(_), do: :warning

  defp normalize_severity(value) when is_atom(value), do: value

  defp normalize_severity(value) when is_binary(value) do
    case String.downcase(value) do
      "emergency" -> :emergency
      "critical" -> :critical
      "high" -> :critical
      "warning" -> :warning
      "warn" -> :warning
      "info" -> :info
      _ -> :warning
    end
  end

  defp event_alert_metadata(event, alert_config) do
    base =
      %{}
      |> maybe_put("event_id", event_id_string(event))
      |> maybe_put("event_time", format_datetime(Map.get(event, :time)))
      |> maybe_put("log_name", Map.get(event, :log_name))
      |> maybe_put("log_provider", Map.get(event, :log_provider))
      |> maybe_put("severity", Map.get(event, :severity))

    alert_config
    |> override_map("metadata")
    |> case do
      %{} = override -> Map.merge(base, override)
      _ -> base
    end
  end

  defp event_id_string(event) do
    case Map.get(event, :id) do
      nil -> nil
      <<_::128>> = bin -> Ecto.UUID.load!(bin)
      id -> to_string(id)
    end
  end

  defp override_string(config, key) do
    case override_map(config, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp override_atom(config, key) do
    case override_map(config, key) do
      value when is_atom(value) -> value
      _ -> nil
    end
  end

  defp override_map(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, atom_key(key))
  end

  defp override_map(_, _), do: nil

  defp atom_key("title"), do: :title
  defp atom_key("description"), do: :description
  defp atom_key("severity"), do: :severity
  defp atom_key("metadata"), do: :metadata
  defp atom_key(_), do: nil
end
