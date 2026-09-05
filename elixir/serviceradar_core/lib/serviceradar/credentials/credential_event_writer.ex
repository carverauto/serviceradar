defmodule ServiceRadar.Credentials.CredentialEventWriter do
  @moduledoc """
  Emits redacted OCSF events for credential lifecycle and broker activity.

  ## Routine resolution-success events are suppressed by default

  Every credential secret resolution used to emit a `"Credential secret
  resolution success"` OCSF event into `ocsf_events`. Because the control plane
  resolves credentials on every agent-config poll, these routine successes were
  by far the single largest contributor to the observability event stream
  (~56% of all `ocsf_events` on the reference deployment) while carrying no
  actionable signal (severity Informational).

  To keep the observability stream signal-rich, routine resolution *successes*
  (outcome `:success` / `:cache_hit`) are **not** written to `ocsf_events` by
  default. Security-relevant outcomes — failures, denials, errors, and
  unavailability — are always written unchanged, since they are actionable audit
  signals.

  No audit coverage is lost: the full per-resolution audit trail (including
  successes) is still persisted separately by
  `ServiceRadar.Credentials.SecretBroker.write_audit/1` into the dedicated
  `credential_secret_resolution_audits` table (with AshPaperTrail versioning).
  This module only governs the noisy OCSF *event* mirror.

  Operators who want a complete success audit trail in the OCSF event stream can
  re-enable success emission via application env:

      config :serviceradar_core, :credential_resolution_audit_success_events, true

  The flag defaults to `false`.

  For broker grant event visibility and history, see "Broker grant logs and
  history" in `docs/docs/credentials.md`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.OcsfEvent

  require Logger

  @doc "Write a provider lifecycle event without leaking provider bootstrap material."
  def write_provider_lifecycle(provider, action) do
    provider
    |> provider_lifecycle_event_attrs(action)
    |> record_event()
  end

  @doc "Write a credential lifecycle event without leaking credential material."
  def write_secret_lifecycle(secret, action) do
    secret
    |> secret_lifecycle_event_attrs(action)
    |> record_event()
  end

  @doc """
  Write a credential resolution audit event to `ocsf_events`.

  Routine resolution successes (outcome `:success` / `:cache_hit`) are skipped by
  default to keep the observability stream signal-rich; non-success outcomes are
  always emitted. See the moduledoc for the
  `:credential_resolution_audit_success_events` override. Returns `:ok` in all
  cases (including the suppressed path).
  """
  def write_secret_resolution(audit_attrs) when is_map(audit_attrs) do
    outcome = normalize_atom(value(audit_attrs, :outcome), :failed)

    if emit_resolution_event?(outcome) do
      audit_attrs
      |> secret_resolution_event_attrs()
      |> record_event()
    else
      :ok
    end
  end

  @doc false
  # Whether a resolution `outcome` should be mirrored into `ocsf_events`.
  # Non-success outcomes (failure/denied/error/unavailable/...) are always
  # emitted; routine successes are emitted only when the operator opts in via
  # `:credential_resolution_audit_success_events`. Exposed for testing.
  def emit_resolution_event?(outcome) do
    not routine_resolution_success?(outcome) or success_events_enabled?()
  end

  @doc """
  Write a broker grant lifecycle record.

  See "Broker grant logs and history" in `docs/docs/credentials.md` for the
  event-emission policy.
  """
  def write_broker_grant_lifecycle(grant, action) do
    attrs = broker_grant_lifecycle_event_attrs(grant, action)

    if emit_grant_lifecycle_event?(action) do
      record_event(attrs)
    else
      log_grant_lifecycle_debug(attrs)
      :ok
    end
  end

  @doc false
  # Unknown actions fail closed to an event, never silently suppressed.
  def emit_grant_lifecycle_event?(action) do
    not routine_grant_lifecycle?(action)
  end

  def provider_lifecycle_event_attrs(provider, action) do
    activity_id = OCSF.activity_log_update()
    severity_id = severity_for_provider_action(action)
    status_id = status_for_action(action)
    provider_id = value(provider, :id)
    provider_name = value(provider, :name)
    provider_type = value(provider, :provider_type)

    base_event_attrs(
      activity_id: activity_id,
      severity_id: severity_id,
      status_id: status_id,
      message:
        "Credential secret provider #{provider_name || provider_id} #{human_action(action)}",
      correlation_uid: "credential_secret_provider:#{provider_id}",
      log_name: "credential.secret_provider.lifecycle",
      metadata: %{
        "event_family" => "credential_secret_provider_lifecycle",
        "credential_secret_provider_id" => stringify(provider_id),
        "credential_secret_provider_name" => provider_name,
        "credential_secret_provider_type" => stringify(provider_type),
        "status" => stringify(value(provider, :status)),
        "enabled" => value(provider, :enabled),
        "action" => stringify(action)
      },
      observables:
        observables([
          observable(provider_id, "Credential Secret Provider ID"),
          observable(provider_name, "Credential Secret Provider Name"),
          observable(provider_type, "Credential Secret Provider Type")
        ])
    )
  end

  def secret_lifecycle_event_attrs(secret, action) do
    activity_id = OCSF.activity_log_update()
    severity_id = severity_for_secret_action(action)
    status_id = status_for_action(action)
    secret_id = value(secret, :id)

    base_event_attrs(
      activity_id: activity_id,
      severity_id: severity_id,
      status_id: status_id,
      message: "Network credential secret #{secret_id} #{human_action(action)}",
      correlation_uid: "network_credential_secret:#{secret_id}",
      log_name: "credential.secret.lifecycle",
      metadata: %{
        "event_family" => "network_credential_secret_lifecycle",
        "network_credential_secret_id" => stringify(secret_id),
        "provider" => value(secret, :provider),
        "credential_kind" => stringify(value(secret, :credential_kind)),
        "source_type" => stringify(value(secret, :source_type)),
        "rotation_state" => stringify(value(secret, :rotation_state)),
        "action" => stringify(action)
      },
      observables:
        observables([
          observable(secret_id, "Network Credential Secret ID"),
          observable(value(secret, :provider), "Credential Provider"),
          observable(value(secret, :credential_kind), "Credential Kind")
        ])
    )
  end

  def secret_resolution_event_attrs(audit_attrs) do
    activity_id = OCSF.activity_log_read()
    outcome = normalize_atom(value(audit_attrs, :outcome), :failed)
    severity_id = severity_for_resolution_outcome(outcome)
    status_id = status_for_outcome(outcome)
    secret_id = value(audit_attrs, :secret_id)
    provider_id = value(audit_attrs, :secret_provider_id)

    metadata =
      CredentialRedactor.redact(%{
        "event_family" => "credential_secret_resolution",
        "network_credential_secret_id" => stringify(secret_id),
        "credential_secret_provider_id" => stringify(provider_id),
        "grant_id" => value(audit_attrs, :grant_id),
        "consumer_kind" => stringify(value(audit_attrs, :consumer_kind)),
        "consumer_id" => value(audit_attrs, :consumer_id),
        "purpose" => value(audit_attrs, :purpose),
        "target_kind" => value(audit_attrs, :target_kind),
        "target_id" => value(audit_attrs, :target_id),
        "agent_id" => value(audit_attrs, :agent_id),
        "resolution_location" => stringify(value(audit_attrs, :resolution_location)),
        "outcome" => stringify(outcome),
        "error_class" => stringify(value(audit_attrs, :error_class)),
        "cache_status" => stringify(value(audit_attrs, :cache_status))
      })

    base_event_attrs(
      activity_id: activity_id,
      severity_id: severity_id,
      status_id: status_id,
      message: "Credential secret resolution #{outcome}",
      correlation_uid: "network_credential_secret:#{secret_id}",
      log_name: "credential.secret_resolution",
      log_level: routine_log_level(severity_id),
      metadata: metadata,
      observables:
        observables([
          observable(secret_id, "Network Credential Secret ID"),
          observable(provider_id, "Credential Secret Provider ID"),
          observable(value(audit_attrs, :consumer_id), "Credential Consumer ID"),
          observable(value(audit_attrs, :target_id), "Credential Target ID")
        ])
    )
  end

  def broker_grant_lifecycle_event_attrs(grant, action) do
    activity_id = OCSF.activity_log_update()
    severity_id = severity_for_grant_action(action)
    status_id = status_for_action(action)
    grant_id = value(grant, :id)
    secret_id = value(grant, :secret_id)

    metadata =
      CredentialRedactor.redact(%{
        "event_family" => "credential_broker_grant_lifecycle",
        "credential_broker_grant_id" => stringify(grant_id),
        "network_credential_secret_id" => stringify(secret_id),
        "credential_rule_id" => stringify(value(grant, :credential_rule_id)),
        "grant_type" => value(grant, :grant_type),
        "consumer_kind" => stringify(value(grant, :consumer_kind)),
        "consumer_id" => value(grant, :consumer_id),
        "purpose" => value(grant, :purpose),
        "target_kind" => value(grant, :target_kind),
        "target_id" => value(grant, :target_id),
        "agent_id" => value(grant, :agent_id),
        "resolution_location" => stringify(value(grant, :resolution_location)),
        "status" => stringify(value(grant, :status)),
        "action" => stringify(action)
      })

    base_event_attrs(
      activity_id: activity_id,
      severity_id: severity_id,
      status_id: status_id,
      message: "Credential broker grant #{grant_id} #{human_action(action)}",
      correlation_uid: "credential_broker_grant:#{grant_id}",
      log_name: "credential.broker_grant.lifecycle",
      log_level: routine_log_level(severity_id),
      metadata: metadata,
      observables:
        observables([
          observable(grant_id, "Credential Broker Grant ID"),
          observable(secret_id, "Network Credential Secret ID"),
          observable(value(grant, :consumer_id), "Credential Consumer ID"),
          observable(value(grant, :target_id), "Credential Target ID")
        ])
    )
  end

  defp base_event_attrs(opts) do
    activity_id = Keyword.fetch!(opts, :activity_id)
    severity_id = Keyword.fetch!(opts, :severity_id)
    status_id = Keyword.fetch!(opts, :status_id)
    now = DateTime.utc_now()

    %{
      time: now,
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      message: Keyword.fetch!(opts, :message),
      status_id: status_id,
      status: OCSF.status_name(status_id),
      status_code: nil,
      status_detail: nil,
      metadata:
        OCSF.build_metadata(
          product_name: "ServiceRadar Core",
          correlation_uid: Keyword.fetch!(opts, :correlation_uid)
        ),
      observables: Keyword.get(opts, :observables, []),
      actor: %{user: %{uid: "system", name: "ServiceRadar Credential Broker"}},
      log_name: Keyword.fetch!(opts, :log_name),
      log_provider: "serviceradar.core",
      log_level: Keyword.get(opts, :log_level) || log_level(severity_id),
      unmapped: Keyword.get(opts, :metadata, %{}),
      raw_data: Jason.encode!(Keyword.get(opts, :metadata, %{}))
    }
  end

  defp record_event(attrs) do
    Ash.create(OcsfEvent, attrs,
      action: :record,
      actor: SystemActor.system(:credential_event_writer),
      domain: ServiceRadar.Monitoring
    )

    :ok
  rescue
    exception ->
      Logger.warning("Failed to write credential OCSF event",
        reason: Exception.message(exception)
      )

      :ok
  end

  defp log_grant_lifecycle_debug(attrs) do
    Logger.debug(attrs.message,
      log_name: attrs.log_name,
      event_family: Map.get(attrs.unmapped, "event_family"),
      action: Map.get(attrs.unmapped, "action"),
      credential_broker_grant_id: Map.get(attrs.unmapped, "credential_broker_grant_id")
    )
  end

  defp severity_for_provider_action(action) when action in [:record_test_unavailable],
    do: OCSF.severity_medium()

  defp severity_for_provider_action(action) when action in [:record_test_failure],
    do: OCSF.severity_low()

  defp severity_for_provider_action(_action), do: OCSF.severity_informational()

  defp severity_for_secret_action(:fail_rotation), do: OCSF.severity_medium()
  defp severity_for_secret_action(_action), do: OCSF.severity_informational()

  defp severity_for_grant_action(action) when action in [:deny, :revoke],
    do: OCSF.severity_medium()

  defp severity_for_grant_action(:expire), do: OCSF.severity_low()
  defp severity_for_grant_action(_action), do: OCSF.severity_informational()

  # Routine successes: resolved from an internal secret or a warm cache. These
  # match the success set of `status_for_outcome/1` and are the high-frequency,
  # non-actionable outcomes suppressed from `ocsf_events` by default.
  defp routine_resolution_success?(outcome) when outcome in [:success, :cache_hit], do: true
  defp routine_resolution_success?(_outcome), do: false

  defp routine_grant_lifecycle?(action) when action in [:issue, :activate, :consume], do: true
  defp routine_grant_lifecycle?(_action), do: false

  defp success_events_enabled? do
    Application.get_env(:serviceradar_core, :credential_resolution_audit_success_events, false) ==
      true
  end

  defp severity_for_resolution_outcome(:success), do: OCSF.severity_informational()
  defp severity_for_resolution_outcome(:cache_hit), do: OCSF.severity_informational()
  defp severity_for_resolution_outcome(:denied), do: OCSF.severity_medium()
  defp severity_for_resolution_outcome(_outcome), do: OCSF.severity_low()

  defp status_for_action(action)
       when action in [:record_test_unavailable, :fail_rotation, :deny, :revoke],
       do: OCSF.status_failure()

  defp status_for_action(_action), do: OCSF.status_success()

  defp status_for_outcome(outcome) when outcome in [:success, :cache_hit],
    do: OCSF.status_success()

  defp status_for_outcome(_outcome), do: OCSF.status_failure()

  defp log_level(severity_id) do
    cond do
      severity_id >= OCSF.severity_critical() -> "critical"
      severity_id >= OCSF.severity_high() -> "error"
      severity_id >= OCSF.severity_medium() -> "warning"
      true -> "info"
    end
  end

  # This tags retained OCSF records; emission is decided by the write functions.
  defp routine_log_level(severity_id) do
    if severity_id <= OCSF.severity_informational() do
      "debug"
    else
      log_level(severity_id)
    end
  end

  defp human_action(action) do
    action
    |> stringify()
    |> String.replace("_", " ")
  end

  defp observables(items), do: Enum.reject(items, &is_nil/1)

  defp observable(nil, _name), do: nil
  defp observable("", _name), do: nil

  defp observable(value, name),
    do: %{
      "name" => stringify(value),
      "type" => "string",
      "value" => stringify(value),
      "caption" => name
    }

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp normalize_atom(value, _default) when is_atom(value), do: value

  defp normalize_atom(value, default) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> default
      trimmed -> String.to_existing_atom(trimmed)
    end
  rescue
    ArgumentError -> default
  end

  defp normalize_atom(_value, default), do: default

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
