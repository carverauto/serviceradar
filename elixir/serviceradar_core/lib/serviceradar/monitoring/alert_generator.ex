defmodule ServiceRadar.Monitoring.AlertGenerator do
  @moduledoc """
  Alert generation service for ServiceRadar monitoring events.

  Creates alerts from various monitoring events:
  - Service state changes (up/down)
  - Device availability changes
  - Poller/agent health issues
  - Metric threshold violations
  - Stats anomalies

  ## Usage

      # Generate alert for service down
      AlertGenerator.service_down(
        service_check_id: "check-123",
        service_name: "web-server",
        poller_id: "poller-1",
        device_uid: "device-456",
        details: %{"error" => "Connection refused"}
      )

      # Generate alert for device offline
      AlertGenerator.device_offline(
        device_uid: "device-456",
        last_seen_at: ~U[2025-01-01 12:00:00Z],
        details: %{"ip" => "192.168.1.100"}
      )
  """

  alias ServiceRadar.Monitoring.{Alert, WebhookNotifier}

  require Logger

  @stats_alert_cooldown :timer.minutes(5)

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
  - `:poller_id` - Poller that detected the outage
  - `:device_uid` - Device the service runs on
  - `:agent_uid` - Agent managing the poller
  - `:error` - Error message/details
  - `:tenant_id` - Tenant ID (required)
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
      metadata: build_metadata(opts),
      tenant_id: Keyword.fetch!(opts, :tenant_id)
    }

    create_alert_and_notify(attrs, opts)
  end

  @doc """
  Generate alert for a service recovering.
  """
  @spec service_recovered(keyword()) :: {:ok, Alert.t()} | {:error, term()}
  def service_recovered(opts) do
    service_name = Keyword.get(opts, :service_name, "Unknown Service")

    # Mark service as recovered in webhook notifier
    if service_id = Keyword.get(opts, :service_check_id) do
      WebhookNotifier.mark_service_recovered(service_id)
    end

    attrs = %{
      title: "Service Recovered: #{service_name}",
      description: "Service #{service_name} is now responding",
      severity: :info,
      source_type: :service_check,
      source_id: Keyword.get(opts, :service_check_id),
      service_check_id: Keyword.get(opts, :service_check_id),
      device_uid: Keyword.get(opts, :device_uid),
      agent_uid: Keyword.get(opts, :agent_uid),
      metadata: build_metadata(opts),
      tenant_id: Keyword.fetch!(opts, :tenant_id)
    }

    create_alert_and_notify(attrs, opts)
  end

  @doc """
  Generate alert for a device going offline.

  ## Options

  - `:device_uid` - Device UID (required)
  - `:last_seen_at` - When the device was last seen
  - `:ip` - Device IP address
  - `:tenant_id` - Tenant ID (required)
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
      metadata: build_metadata(opts),
      tenant_id: Keyword.fetch!(opts, :tenant_id)
    }

    create_alert_and_notify(attrs, opts)
  end

  @doc """
  Generate alert for a poller going offline.

  ## Options

  - `:poller_id` - Poller ID (required)
  - `:agent_uid` - Agent UID
  - `:partition` - Partition the poller belongs to
  - `:tenant_id` - Tenant ID (required)
  """
  @spec poller_offline(keyword()) :: {:ok, Alert.t()} | {:error, term()}
  def poller_offline(opts) do
    poller_id = Keyword.fetch!(opts, :poller_id)

    attrs = %{
      title: "Node Offline",
      description: "Poller #{poller_id} is not responding",
      severity: :critical,
      source_type: :poller,
      source_id: poller_id,
      agent_uid: Keyword.get(opts, :agent_uid),
      metadata: build_metadata(opts),
      tenant_id: Keyword.fetch!(opts, :tenant_id)
    }

    create_alert_and_notify(attrs, opts)
  end

  @doc """
  Generate alert for a poller recovery.
  """
  @spec poller_recovered(keyword()) :: {:ok, Alert.t()} | {:error, term()}
  def poller_recovered(opts) do
    poller_id = Keyword.fetch!(opts, :poller_id)

    # Mark poller as recovered in webhook notifier
    WebhookNotifier.mark_poller_recovered(poller_id)

    attrs = %{
      title: "Node Online",
      description: "Poller #{poller_id} is now responding",
      severity: :info,
      source_type: :poller,
      source_id: poller_id,
      agent_uid: Keyword.get(opts, :agent_uid),
      metadata: build_metadata(opts),
      tenant_id: Keyword.fetch!(opts, :tenant_id)
    }

    create_alert_and_notify(attrs, opts)
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
      metadata: build_metadata(opts),
      tenant_id: Keyword.fetch!(opts, :tenant_id)
    }

    create_alert_and_notify(attrs, opts)
  end

  @doc """
  Generate alert for a metric threshold violation.

  ## Options

  - `:metric_name` - Name of the metric (required)
  - `:metric_value` - Current value (required)
  - `:threshold_value` - Threshold that was violated (required)
  - `:comparison` - How value compared (:greater_than, :less_than, etc.)
  - `:device_uid` - Device the metric belongs to
  - `:tenant_id` - Tenant ID (required)
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
      metadata: build_metadata(opts),
      tenant_id: Keyword.fetch!(opts, :tenant_id)
    }

    create_alert_and_notify(attrs, opts)
  end

  @doc """
  Handle stats anomaly alert (non-canonical devices filtered).

  Port of Go's handleStatsAnomaly function.
  """
  @spec stats_anomaly(map(), keyword()) :: :ok | {:error, term()}
  def stats_anomaly(meta, _opts \\ []) do
    skipped = meta[:skipped_non_canonical] || meta["skipped_non_canonical"] || 0

    # Check cooldown
    {last_count, last_time} = get_last_stats_alert()
    now = DateTime.utc_now()

    if skipped <= last_count and
         DateTime.diff(now, last_time, :millisecond) < @stats_alert_cooldown do
      :ok
    else
      set_last_stats_alert(skipped, now)

      delta = skipped - last_count

      if delta > 0 do
        message =
          "Stats aggregator filtered #{delta} newly detected non-canonical devices (total filtered: #{skipped})."

        details =
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

        alert = %WebhookNotifier.Alert{
          level: :warning,
          title: "Non-canonical devices filtered from stats",
          message: message,
          timestamp: DateTime.to_iso8601(now),
          poller_id: "core",
          details: details
        }

        case WebhookNotifier.send_alert(alert) do
          :ok -> :ok
          {:error, :not_running} -> :ok
          error -> error
        end
      else
        :ok
      end
    end
  end

  @doc """
  Send startup notification.
  """
  @spec startup_notification(keyword()) :: :ok
  def startup_notification(opts \\ []) do
    hostname = Keyword.get(opts, :hostname, get_hostname())
    version = Keyword.get(opts, :version, "unknown")

    alert = %WebhookNotifier.Alert{
      level: :info,
      title: "Core Service Started",
      message:
        "ServiceRadar core service initialized at #{DateTime.to_iso8601(DateTime.utc_now())}",
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      poller_id: "core",
      details: %{
        "version" => version,
        "hostname" => hostname
      }
    }

    case WebhookNotifier.send_alert(alert) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  @doc """
  Send shutdown notification.
  """
  @spec shutdown_notification(keyword()) :: :ok
  def shutdown_notification(opts \\ []) do
    hostname = Keyword.get(opts, :hostname, get_hostname())

    alert = %WebhookNotifier.Alert{
      level: :warning,
      title: "Core Service Stopping",
      message:
        "ServiceRadar core service shutting down at #{DateTime.to_iso8601(DateTime.utc_now())}",
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      poller_id: "core",
      details: %{
        "hostname" => hostname
      }
    }

    case WebhookNotifier.send_alert(alert) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  # Private functions

  defp create_alert_and_notify(attrs, opts) do
    # Create the alert in the database
    case Alert
         |> Ash.Changeset.for_create(:trigger, attrs)
         |> Ash.create() do
      {:ok, alert} ->
        # Also send webhook notification
        send_webhook_notification(alert, opts)
        {:ok, alert}

      {:error, error} ->
        Logger.error("Failed to create alert: #{inspect(error)}")
        {:error, error}
    end
  end

  defp send_webhook_notification(alert, opts) do
    webhook_alert = %WebhookNotifier.Alert{
      level: severity_to_level(alert.severity),
      title: alert.title,
      message: alert.description,
      timestamp: alert.triggered_at |> DateTime.to_iso8601(),
      poller_id: Keyword.get(opts, :poller_id, "core"),
      service_name: nil,
      details: alert.metadata || %{}
    }

    case WebhookNotifier.send_alert(webhook_alert) do
      :ok ->
        Logger.debug("Webhook notification sent for alert: #{alert.title}")

      {:error, :not_running} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to send webhook notification: #{inspect(reason)}")
    end
  end

  defp severity_to_level(:emergency), do: :error
  defp severity_to_level(:critical), do: :error
  defp severity_to_level(:warning), do: :warning
  defp severity_to_level(:info), do: :info
  defp severity_to_level(_), do: :warning

  defp build_metadata(opts) do
    details = Keyword.get(opts, :details, %{})

    base_metadata =
      %{}
      |> maybe_put("poller_id", Keyword.get(opts, :poller_id))
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

  defp get_hostname do
    case :inet.gethostname() do
      {:ok, hostname} -> to_string(hostname)
      _ -> "unknown"
    end
  end
end
