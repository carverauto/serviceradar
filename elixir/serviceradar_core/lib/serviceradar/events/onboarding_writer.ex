defmodule ServiceRadar.Events.OnboardingWriter do
  @moduledoc """
  Writes edge onboarding lifecycle events into the tenant OCSF events table.
  """

  alias ServiceRadar.Edge.OnboardingEvent
  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.Monitoring.OcsfEvent

  require Logger

  @spec write(OnboardingEvent.t(), String.t() | nil) :: :ok | {:error, term()}
  def write(_event, nil), do: {:error, :missing_tenant_schema}

  def write(%OnboardingEvent{} = event, tenant_schema) do
    with {:ok, package} <- load_package(event, tenant_schema),
         {:ok, tenant_id} <- fetch_tenant_id(package) do
      attrs = build_event_attrs(event, package, tenant_id)

      OcsfEvent
      |> Ash.Changeset.for_create(:record, attrs, tenant: tenant_schema)
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, record} ->
          EventsPubSub.broadcast_event(record)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e ->
      Logger.warning("Failed to write onboarding OCSF event: #{inspect(e)}")
      {:error, e}
  end

  defp load_package(event, tenant_schema) do
    case Ash.get(OnboardingPackage, event.package_id, tenant: tenant_schema, authorize?: false) do
      {:ok, package} -> {:ok, package}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_tenant_id(%OnboardingPackage{tenant_id: tenant_id}) when is_binary(tenant_id) do
    {:ok, tenant_id}
  end

  defp fetch_tenant_id(_), do: {:error, :missing_tenant_id}

  defp build_event_attrs(event, package, tenant_id) do
    activity_id = OCSF.activity_log_update()
    {status_id, severity_id, log_name} = classify_event(event.event_type)
    message = build_message(event, package)

    %{
      time: event.event_time || DateTime.utc_now(),
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      message: message,
      status_id: status_id,
      status: OCSF.status_name(status_id),
      metadata:
        OCSF.build_metadata(
          version: "1.7.0",
          product_name: "ServiceRadar Core",
          correlation_uid: "edge_onboarding:#{event.package_id}"
        ),
      observables: build_observables(event, package),
      actor: build_actor(event.actor),
      src_endpoint: build_endpoint(event.source_ip),
      log_name: log_name,
      log_provider: "serviceradar.core",
      log_level: log_level_for_severity(severity_id),
      unmapped: build_unmapped(event, package),
      tenant_id: tenant_id
    }
  end

  defp classify_event(event_type) do
    case event_type do
      type when type in [:revoked, :deleted, :expired] ->
        {OCSF.status_failure(), OCSF.severity_medium(), "edge.onboarding.failed"}

      _ ->
        {OCSF.status_success(), OCSF.severity_informational(), "edge.onboarding.activity"}
    end
  end

  defp build_message(event, package) do
    "Edge onboarding package #{package.label || package.id} #{event.event_type}"
  end

  defp build_observables(event, package) do
    [
      OCSF.build_observable(to_string(event.package_id), "Onboarding Package ID", 99),
      OCSF.build_observable(package.label || to_string(event.package_id), "Onboarding Package", 99)
    ]
  end

  defp build_actor(nil) do
    OCSF.build_actor(app_name: "serviceradar.core", process: "edge_onboarding")
  end

  defp build_actor(actor) do
    OCSF.build_actor(
      app_name: "serviceradar.core",
      process: "edge_onboarding",
      user: %{email_addr: actor, name: actor}
    )
  end

  defp build_endpoint(nil), do: %{}
  defp build_endpoint(ip), do: OCSF.build_endpoint(ip: ip)

  defp build_unmapped(event, package) do
    %{
      "package_id" => to_string(event.package_id),
      "package_label" => package.label,
      "event_type" => to_string(event.event_type),
      "actor" => event.actor,
      "source_ip" => event.source_ip,
      "details" => event.details_json || %{}
    }
  end

  defp log_level_for_severity(severity_id) do
    case severity_id do
      6 -> "fatal"
      5 -> "critical"
      4 -> "error"
      3 -> "warning"
      2 -> "notice"
      1 -> "info"
      _ -> "unknown"
    end
  end
end
