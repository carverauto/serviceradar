defmodule ServiceRadar.Observability.AnomalyAlertLivenessCheck do
  @moduledoc """
  End-to-end liveness check for the anomaly stateful-alert pipeline.

  The check injects a synthetic confirmed anomaly open event directly into the
  stateful alert engine, verifies that the seeded anomaly rule created a
  persisted alert, injects a clear event, and verifies that the alert resolves.
  Synthetic artifacts are marked as internal, excluded from outbound delivery,
  and discarded after verification so the probe never surfaces as a customer
  finding.
  It is designed for post-deploy smoke checks where a silent rule-shape or signal
  rename regression must fail the rollout.
  """

  alias Ash.Page.Keyset
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.Observability.RuleSeeder
  alias ServiceRadar.Observability.StatefulAlertEngine
  alias ServiceRadar.Observability.StatefulAlertRule

  require Ash.Query

  @rule_name "causal_prediction_health_finding"
  @alert_title "Anomaly Finding"
  @default_device_uid "sr:anomaly-alert-liveness"
  @default_timeout_ms 5_000
  @poll_ms 100
  @probe_alert_scan_limit 25

  @type result :: %{
          rule_id: String.t(),
          alert_id: String.t(),
          device_uid: String.t(),
          series_key: String.t(),
          opened_at: DateTime.t(),
          resolved_at: DateTime.t() | nil
        }

  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    device_uid = Keyword.get(opts, :device_uid, @default_device_uid)
    series_key = Keyword.get(opts, :series_key, unique_series_key(now))
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    actor = Keyword.get(opts, :actor, SystemActor.system(:anomaly_alert_liveness))

    with :ok <- seed_rules(),
         {:ok, rule} <- load_rule(actor),
         :ok <- assert_rule_contract(rule),
         :ok <- StatefulAlertEngine.evaluate_events([event(:open, now, device_uid, series_key)]),
         {:ok, alert} <- wait_for_alert(actor, series_key, timeout_ms),
         clear_time = DateTime.add(now, 30, :second),
         :ok <-
           StatefulAlertEngine.evaluate_events([
             event(:clear, clear_time, device_uid, series_key)
           ]),
         {:ok, resolved} <- wait_for_resolved(actor, alert.id, timeout_ms),
         :ok <- discard_probe_artifacts(resolved) do
      {:ok,
       %{
         rule_id: to_string(rule.id),
         alert_id: to_string(alert.id),
         device_uid: device_uid,
         series_key: series_key,
         opened_at: alert.triggered_at,
         resolved_at: resolved.resolved_at
       }}
    end
  end

  @doc """
  Best-effort cleanup after an interrupted run: injects the synthetic clear
  transition for `series_key`, resolves any lingering liveness alert, and
  discards its internal alert/event artifacts. Safe when nothing is open — the
  engine treats an unmatched clear as a no-op.
  """
  @spec emit_clear(String.t(), keyword()) :: :ok | {:error, term()}
  def emit_clear(series_key, opts \\ []) when is_binary(series_key) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    device_uid = Keyword.get(opts, :device_uid, @default_device_uid)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    actor = Keyword.get(opts, :actor, SystemActor.system(:anomaly_alert_liveness))
    alert = probe_alert_for_series(actor, series_key)

    with :ok <- StatefulAlertEngine.evaluate_events([event(:clear, now, device_uid, series_key)]) do
      maybe_discard_active_probe(actor, alert, timeout_ms)
    end
  end

  defp maybe_discard_active_probe(_actor, nil, _timeout_ms), do: :ok

  defp maybe_discard_active_probe(actor, alert, timeout_ms) do
    with {:ok, resolved} <- wait_for_resolved(actor, alert.id, timeout_ms) do
      discard_probe_artifacts(resolved)
    end
  end

  defp discard_probe_artifacts(%Alert{} = alert) do
    actor = SystemActor.system(:anomaly_alert_liveness_cleanup)

    with :ok <- discard_probe_event(actor, alert) do
      discard_probe_alert(actor, alert)
    end
  end

  defp discard_probe_event(actor, %Alert{event_id: event_id, event_time: event_time})
       when is_binary(event_id) and not is_nil(event_time) do
    query =
      OcsfEvent
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(id == ^event_id and time == ^event_time)

    case Ash.read_one(query, actor: actor) do
      {:ok, nil} ->
        :ok

      {:ok, event} ->
        event
        |> Ash.Changeset.for_destroy(:discard_internal_probe, %{}, actor: actor)
        |> Ash.destroy()
        |> normalize_discard_result(:event)

      {:error, reason} ->
        {:error, {:synthetic_event_lookup_failed, reason}}
    end
  end

  defp discard_probe_event(_actor, _alert), do: {:error, :synthetic_event_identity_missing}

  defp discard_probe_alert(actor, alert) do
    alert
    |> Ash.Changeset.for_destroy(:discard_internal_probe, %{}, actor: actor)
    |> Ash.destroy()
    |> normalize_discard_result(:alert)
  end

  defp normalize_discard_result(:ok, _artifact), do: :ok
  defp normalize_discard_result({:ok, _record}, _artifact), do: :ok

  defp normalize_discard_result({:error, reason}, artifact),
    do: {:error, {:synthetic_artifact_cleanup_failed, artifact, reason}}

  defp seed_rules do
    case RuleSeeder.seed_all() do
      :ok -> :ok
      nil -> {:error, :rule_seeder_disabled}
      other -> {:error, {:unexpected_rule_seeder_result, other}}
    end
  end

  defp load_rule(actor) do
    query =
      StatefulAlertRule
      |> Ash.Query.for_read(:active, %{}, actor: actor)
      |> Ash.Query.filter(name == @rule_name)

    case Ash.read(query, actor: actor) do
      {:ok, %Keyset{results: [rule]}} -> {:ok, rule}
      {:ok, [rule]} -> {:ok, rule}
      {:ok, []} -> {:error, {:missing_or_disabled_rule, @rule_name}}
      {:ok, rules} -> {:error, {:ambiguous_rule, @rule_name, length(rules)}}
      {:error, reason} -> {:error, {:rule_load_failed, reason}}
    end
  end

  defp assert_rule_contract(rule) do
    match = rule.match || %{}
    attrs = Map.get(match, "attribute_equals") || %{}
    recovery_attrs = get_in(match, ["recovery", "attribute_equals"]) || %{}

    cond do
      not value_matches?(Map.get(match, "subject_prefix"), "signals.analytics.predictions") ->
        {:error, {:stale_rule_contract, @rule_name, :subject_prefix}}

      not value_matches?(Map.get(attrs, "signal_type"), "prediction") ->
        {:error, {:stale_rule_contract, @rule_name, :signal_type}}

      not value_matches?(Map.get(attrs, "event_type"), "anomaly") ->
        {:error, {:stale_rule_contract, @rule_name, :event_type}}

      not value_matches?(Map.get(attrs, "anomaly.state"), "anomaly_drift_open") ->
        {:error, {:stale_rule_contract, @rule_name, :drift_open_state}}

      not value_matches?(Map.get(recovery_attrs, "anomaly.state"), "anomaly_drift_clear") ->
        {:error, {:stale_rule_contract, @rule_name, :drift_clear_state}}

      true ->
        :ok
    end
  end

  defp value_matches?(values, value) when is_list(values), do: value in values
  defp value_matches?(value, value), do: true
  defp value_matches?(_values, _value), do: false

  defp wait_for_alert(actor, series_key, timeout_ms) do
    wait_until(timeout_ms, fn ->
      case active_alert_for_series(actor, series_key) do
        nil -> :pending
        alert -> {:ok, alert}
      end
    end)
  end

  defp wait_for_resolved(actor, alert_id, timeout_ms) do
    wait_until(timeout_ms, fn ->
      case Alert.get_by_id(alert_id, actor: actor) do
        {:ok, %Alert{status: :resolved} = alert} -> {:ok, alert}
        {:ok, _alert} -> :pending
        {:error, reason} -> {:error, {:alert_lookup_failed, reason}}
      end
    end)
  end

  defp wait_until(timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    case fun.() do
      {:ok, _value} = ok ->
        ok

      {:error, _reason} = error ->
        error

      :pending ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :anomaly_alert_liveness_timeout}
        else
          Process.sleep(@poll_ms)
          do_wait_until(deadline, fun)
        end
    end
  end

  defp active_alert_for_series(actor, series_key) do
    Alert
    |> Ash.Query.for_read(:active, %{}, actor: actor)
    |> Ash.read(actor: actor)
    |> unwrap_results()
    |> Enum.find(fn alert ->
      alert.title == @alert_title and
        get_in(alert.metadata || %{}, ["incident_group_values", "anomaly.series_key"]) ==
          series_key
    end)
  end

  defp probe_alert_for_series(actor, series_key) do
    Alert
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(title == @alert_title and source_type == :event)
    |> Ash.Query.sort(event_time: :desc)
    |> Ash.Query.limit(@probe_alert_scan_limit)
    |> Ash.read(actor: actor)
    |> unwrap_results()
    |> Enum.find(fn alert ->
      metadata = alert.metadata || %{}

      metadata["synthetic_liveness_check"] == true and
        metadata["synthetic_liveness_series_key"] == series_key
    end)
  end

  defp unwrap_results({:ok, %Keyset{results: results}}), do: results
  defp unwrap_results({:ok, results}) when is_list(results), do: results
  defp unwrap_results(_), do: []

  defp event(:open, now, device_uid, series_key) do
    event(
      now,
      device_uid,
      series_key,
      "anomaly_drift_open",
      "Synthetic anomaly alert liveness open"
    )
  end

  defp event(:clear, now, device_uid, series_key) do
    event(
      now,
      device_uid,
      series_key,
      "anomaly_drift_clear",
      "Synthetic anomaly alert liveness clear"
    )
  end

  defp event(now, device_uid, series_key, state, message) do
    %{
      id: Ash.UUID.generate(),
      time: now,
      severity_id: 4,
      severity: "High",
      message: message,
      log_name: "signals.analytics.predictions.#{series_key}",
      log_provider: "anomaly_detection",
      device: %{"uid" => device_uid},
      unmapped: %{
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "anomaly" => %{
          "state" => state,
          "series_key" => series_key,
          "metric_class" => "liveness",
          "metric_name" => "anomaly_alert_liveness"
        }
      },
      metadata: %{
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "service_radar" => %{
          "device_uid" => device_uid,
          "series_key" => series_key,
          "synthetic_liveness_check" => true
        }
      }
    }
  end

  defp unique_series_key(%DateTime{} = now) do
    suffix = System.unique_integer([:positive, :monotonic])
    "synthetic:anomaly-alert-liveness:#{DateTime.to_unix(now, :microsecond)}:#{suffix}"
  end
end
