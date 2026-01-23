defmodule ServiceRadar.Inventory.MetricRuleSync do
  @moduledoc """
  Sync metric-derived EventRules and StatefulAlertRules from interface settings.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.InterfaceSettings
  alias ServiceRadar.Observability.{EventRule, StatefulAlertRule}

  require Logger
  require Ash.Query

  @spec sync(InterfaceSettings.t()) :: :ok
  def sync(%InterfaceSettings{} = settings) do
    actor = SystemActor.system(:metric_rule_sync)
    thresholds = normalize_thresholds(settings.metric_thresholds)

    Enum.each(thresholds, fn {metric, config} ->
      metric_name = normalize_metric_name(metric)
      sync_event_rule(settings, metric_name, config, actor)
      sync_alert_rule(settings, metric_name, config, actor)
    end)

    :ok
  rescue
    error ->
      Logger.warning("Metric rule sync failed: #{inspect(error)}")
      :ok
  end

  defp sync_event_rule(settings, metric_name, config, actor) do
    name = metric_event_rule_name(settings, metric_name)
    enabled = metric_rule_enabled?(settings, metric_name, config)

    attrs = %{
      name: name,
      enabled: enabled,
      priority: 100,
      source_type: :metric,
      source: %{
        "device_id" => settings.device_id,
        "interface_uid" => settings.interface_uid,
        "metric" => metric_name
      },
      match: %{},
      event: event_map(config)
    }

    upsert_rule(EventRule, name, attrs, actor)
  end

  defp sync_alert_rule(settings, metric_name, config, actor) do
    alert_config = config_value(config, :alert)

    if is_map(alert_config) do
      name = metric_alert_rule_name(settings, metric_name)
      enabled = alert_enabled?(settings, metric_name, config, alert_config)

      attrs = %{
        name: name,
        enabled: enabled,
        priority: 100,
        signal: :event,
        match: alert_match(settings, metric_name),
        group_by: alert_group_by(),
        threshold: config_value(alert_config, :threshold, 1),
        window_seconds: config_value(alert_config, :window_seconds, 300),
        bucket_seconds: config_value(alert_config, :bucket_seconds, 60),
        cooldown_seconds: config_value(alert_config, :cooldown_seconds, 300),
        renotify_seconds: config_value(alert_config, :renotify_seconds, 21_600),
        event: alert_event_map(settings, metric_name, alert_config),
        alert: alert_map(settings, metric_name, alert_config)
      }

      upsert_rule(StatefulAlertRule, name, attrs, actor)
    else
      :ok
    end
  end

  defp upsert_rule(resource, name, attrs, actor) do
    query =
      resource
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(name == ^name)

    case Ash.read_one(query, actor: actor) do
      {:ok, nil} ->
        resource
        |> Ash.Changeset.for_create(:create, attrs, actor: actor)
        |> Ash.create()
        |> log_result(resource, name, :create)

      {:ok, rule} ->
        rule
        |> Ash.Changeset.for_update(:update, attrs, actor: actor)
        |> Ash.update()
        |> log_result(resource, name, :update)

      {:error, reason} ->
        Logger.warning("Failed to load #{resource} #{name}: #{inspect(reason)}")
        :error
    end
  end

  defp log_result({:ok, _}, _resource, _name, _action), do: :ok

  defp log_result({:error, reason}, resource, name, action) do
    Logger.warning("Failed to #{action} #{resource} #{name}: #{inspect(reason)}")

    :error
  end

  defp metric_event_rule_name(settings, metric_name) do
    "metric:event:#{settings.device_id}:#{settings.interface_uid}:#{metric_name}"
  end

  defp metric_alert_rule_name(settings, metric_name) do
    "metric:alert:#{settings.device_id}:#{settings.interface_uid}:#{metric_name}"
  end

  defp metric_rule_enabled?(settings, metric_name, config) do
    selected = normalize_metric_name(metric_name) in normalize_selected(settings.metrics_selected)
    enabled = config_bool(config, :enabled, true)
    comparison = blank_to_nil(config_value(config, :comparison))
    value = config_value(config, :value)

    selected and enabled and not is_nil(comparison) and not is_nil(value)
  end

  defp alert_enabled?(settings, metric_name, config, alert_config) do
    metric_rule_enabled?(settings, metric_name, config) and
      config_bool(alert_config, :enabled, false)
  end

  defp alert_match(settings, metric_name) do
    %{
      "resource_attribute_equals" => %{
        "serviceradar.device_id" => settings.device_id,
        "serviceradar.interface_uid" => settings.interface_uid,
        "serviceradar.metric" => metric_name
      }
    }
  end

  defp alert_group_by do
    ["serviceradar.device_id", "serviceradar.interface_uid", "serviceradar.metric"]
  end

  defp alert_map(settings, metric_name, alert_config) do
    base = %{}
    base = maybe_put(base, "severity", config_value(alert_config, :severity))

    base
    |> maybe_put("title", config_value(alert_config, :title) || default_alert_title(metric_name))
    |> maybe_put(
      "description",
      config_value(alert_config, :description) || default_alert_description(settings, metric_name)
    )
  end

  defp alert_event_map(_settings, metric_name, alert_config) do
    base = %{}
    message = config_value(alert_config, :event_message)
    maybe_put(base, "message", message || "Metric #{metric_name} triggered alert")
  end

  defp event_map(config) do
    event_config = config_value(config, :event)

    if is_map(event_config) do
      event_config
    else
      %{}
    end
  end

  defp default_alert_title(metric_name) do
    "Metric alert: #{metric_name}"
  end

  defp default_alert_description(settings, metric_name) do
    "Metric #{metric_name} exceeded threshold on #{settings.interface_uid}"
  end

  defp normalize_selected(metrics) when is_list(metrics) do
    Enum.map(metrics, &normalize_metric_name/1)
  end

  defp normalize_selected(_), do: []

  defp normalize_metric_name(metric) when is_atom(metric), do: Atom.to_string(metric)
  defp normalize_metric_name(metric) when is_binary(metric), do: metric
  defp normalize_metric_name(metric), do: to_string(metric)

  defp normalize_thresholds(metrics) when is_map(metrics), do: metrics
  defp normalize_thresholds(_), do: %{}

  defp config_value(config, key, default \\ nil) when is_map(config) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key)) || default
  end

  defp config_bool(config, key, default) when is_map(config) do
    case config_value(config, key) do
      nil -> default
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(value) in ["true", "1", "yes", "on"]
      value -> !!value
    end
  end

  defp config_bool(_config, _key, default), do: default

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
