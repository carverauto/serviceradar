defmodule ServiceRadar.DeclarativeChecks.VerdictEventWriter do
  @moduledoc """
  Publishes OCSF `health.state_change` events via `ServiceRadar.Events.OcsfEventPublisher`
  (`family: :declarative_check`) to NATS JetStream whenever a `DeclarativeCheckInstance`
  transitions verdict or status and `alert_policy.emit_ocsf_transition` is enabled (`2.4`).

  `EventWriter` persists the event to the active telemetry backend (StarRocks when
  enabled, CNPG when disabled) and evaluates `StatefulAlertRule` incident promotion.
  Publish failures are logged and swallowed so persisted state transitions never
  roll back on transient NATS errors.
  """

  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Events.OcsfEventPublisher
  alias ServiceRadar.EventWriter.OCSF

  require Logger

  @log_name "declarative_check.health.state_change"

  @doc "The canonical OCSF `log_name` emitted for declarative check transitions."
  @spec log_name() :: String.t()
  def log_name, do: @log_name

  @doc """
  Publishes OCSF transition events for `transitions` when `alert_policy.emit_ocsf_transition`
  is enabled on `check`.
  """
  @spec write_transitions(map(), [map()], keyword()) :: :ok
  def write_transitions(check, transitions, opts \\ [])
      when is_map(check) and is_list(transitions) and is_list(opts) do
    if transitions != [] and emit_enabled?(check) do
      Enum.each(transitions, &write_transition(check, &1, opts))
    end

    :ok
  end

  @doc """
  Builds the OCSF event attributes for one declarative check verdict transition.
  """
  @spec event_attrs(map(), map()) :: map()
  def event_attrs(check, transition) when is_map(check) and is_map(transition) do
    activity_id = OCSF.activity_log_update()

    to_status =
      normalize_status(Map.get(transition, :to_status) || Map.get(transition, "to_status"))

    severity_id = severity_for(to_status)
    status_id = OCSF.status_success()
    unmapped = build_unmapped(check, transition, to_status)
    slug = to_string(Map.get(check, :slug) || Map.get(check, "slug") || "")

    target_key =
      to_string(
        Map.get(transition, :target_key) || Map.get(transition, "target_key") || "singleton"
      )

    %{
      time: Map.get(transition, :evaluated_at) || DateTime.utc_now(),
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      message: build_message(check, transition),
      status_id: status_id,
      status: OCSF.status_name(status_id),
      metadata:
        OCSF.build_metadata(
          product_name: "ServiceRadar Core",
          correlation_uid: "declarative_check:#{slug}:#{target_key}"
        ),
      observables: [],
      actor: %{user: %{uid: "system", name: "ServiceRadar Declarative Checks"}},
      device: build_device(transition),
      log_name: @log_name,
      log_provider: "serviceradar.core",
      unmapped: unmapped,
      raw_data: Jason.encode!(unmapped)
    }
  end

  defp write_transition(check, transition, opts) do
    attrs = event_attrs(check, transition)

    pub_opts =
      Keyword.put(Keyword.take(opts, [:publish, :suppress?]), :family, :declarative_check)

    result =
      case Keyword.get(opts, :event_publisher) do
        fun when is_function(fun, 2) -> fun.(attrs, pub_opts)
        _ -> OcsfEventPublisher.publish(attrs, pub_opts)
      end

    case result do
      {:ok, _event} ->
        :ok

      {:error, :suppressed} ->
        :ok

      {:error, error} ->
        log_failure(check, transition, inspect(error))
    end
  rescue
    exception -> log_failure(check, transition, Exception.message(exception))
  end

  defp log_failure(check, transition, reason) do
    Logger.warning("Failed to publish declarative check transition event",
      check_id: Map.get(check, :id) || Map.get(check, "id"),
      target_key: Map.get(transition, :target_key) || Map.get(transition, "target_key"),
      reason: reason
    )

    :ok
  end

  defp emit_enabled?(check) do
    policy = Map.get(check, :alert_policy) || Map.get(check, "alert_policy") || %{}

    case Map.get(policy, "emit_ocsf_transition", Map.get(policy, :emit_ocsf_transition, true)) do
      false -> false
      _ -> true
    end
  end

  defp build_message(check, transition) do
    name = Map.get(check, :name) || Map.get(check, "name") || Map.get(check, :slug) || "check"

    target_key =
      Map.get(transition, :target_key) || Map.get(transition, "target_key") || "singleton"

    from_v = Map.get(transition, :from_verdict) || Map.get(transition, "from_verdict") || "none"
    to_v = Map.get(transition, :to_verdict) || Map.get(transition, "to_verdict") || "unknown"

    "Declarative check #{name} (#{target_key}) changed from #{from_v} to #{to_v}"
  end

  defp build_unmapped(check, transition, to_status) do
    from_status = Map.get(transition, :from_status) || Map.get(transition, "from_status")

    CredentialRedactor.redact(%{
      "event_family" => "health.state_change",
      "check_id" => to_string(Map.get(check, :id) || Map.get(check, "id") || ""),
      "check_slug" => Map.get(check, :slug) || Map.get(check, "slug"),
      "check_name" => Map.get(check, :name) || Map.get(check, "name"),
      "target_key" =>
        Map.get(transition, :target_key) || Map.get(transition, "target_key") || "singleton",
      "device_uid" => Map.get(transition, :device_uid) || Map.get(transition, "device_uid"),
      "service_target_id" =>
        Map.get(transition, :service_target_id) || Map.get(transition, "service_target_id"),
      "from_verdict" => Map.get(transition, :from_verdict) || Map.get(transition, "from_verdict"),
      "to_verdict" => Map.get(transition, :to_verdict) || Map.get(transition, "to_verdict"),
      "from_status" => from_status && to_string(from_status),
      "to_status" => Atom.to_string(to_status),
      "summary" => Map.get(transition, :summary) || Map.get(transition, "summary")
    })
  end

  defp build_device(transition) do
    case Map.get(transition, :device_uid) || Map.get(transition, "device_uid") do
      uid when is_binary(uid) and uid != "" -> %{"uid" => uid}
      _ -> %{}
    end
  end

  defp severity_for(:down), do: OCSF.severity_high()
  defp severity_for(:degraded), do: OCSF.severity_medium()
  defp severity_for(_status), do: OCSF.severity_informational()

  defp normalize_status(s) when s in [:healthy, :degraded, :down, :unknown], do: s
  defp normalize_status("healthy"), do: :healthy
  defp normalize_status("degraded"), do: :degraded
  defp normalize_status("down"), do: :down
  defp normalize_status(_), do: :unknown
end
