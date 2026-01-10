defmodule ServiceRadar.Events.SyncWriter do
  @moduledoc """
  Writes sync ingestion lifecycle events into the tenant OCSF events table.
  """

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Monitoring.OcsfEvent

  require Logger

  @spec write_start(IntegrationSource.t(), keyword()) :: :ok | {:error, term()}
  def write_start(%IntegrationSource{} = source, opts \\ []) do
    write_event(source, :started, opts)
  end

  @spec write_finish(IntegrationSource.t(), keyword()) :: :ok | {:error, term()}
  def write_finish(%IntegrationSource{} = source, opts \\ []) do
    write_event(source, :finished, opts)
  end

  defp write_event(%IntegrationSource{} = source, stage, opts) do
    with {:ok, schema} <- resolve_schema(source.tenant_id) do
      attrs = build_event_attrs(source, stage, opts)

      OcsfEvent
      |> Ash.Changeset.for_create(:record, attrs, tenant: schema)
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
      Logger.warning("Failed to write sync ingestion event: #{inspect(e)}")
      {:error, e}
  end

  defp resolve_schema(nil), do: {:error, :missing_tenant_id}

  defp resolve_schema(tenant_id) do
    tenant_id_str = to_string(tenant_id)

    case TenantSchemas.schema_for_id(tenant_id_str) do
      nil ->
        Logger.error("Could not resolve tenant schema for tenant_id: #{tenant_id_str}")
        {:error, {:unknown_tenant, tenant_id_str}}

      schema ->
        {:ok, schema}
    end
  end

  defp build_event_attrs(source, stage, opts) do
    result = Keyword.get(opts, :result)
    device_count = Keyword.get(opts, :device_count, 0)
    error_message = Keyword.get(opts, :error_message)
    time = Keyword.get(opts, :time, DateTime.utc_now())

    {status_id, severity_id, log_name, message} =
      classify_stage(stage, result, source, device_count, error_message)

    activity_id = OCSF.activity_log_update()

    %{
      time: time,
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
          correlation_uid: "integration_source:#{source.id}"
        ),
      observables: build_observables(source),
      actor: OCSF.build_actor(app_name: "serviceradar.core", process: "sync_ingestor"),
      log_name: log_name,
      log_provider: "serviceradar.core",
      log_level: log_level_for_severity(severity_id),
      unmapped: build_unmapped(source, stage, result, device_count, error_message),
      tenant_id: source.tenant_id
    }
  end

  defp classify_stage(:started, _result, source, device_count, _error_message) do
    message = "Sync ingestion started for #{source.name} (#{device_count} updates)"
    {OCSF.status_success(), OCSF.severity_informational(), "sync.ingestor.started", message}
  end

  defp classify_stage(:finished, result, source, device_count, error_message) do
    status =
      if result in [:failed, :timeout] do
        :failure
      else
        :success
      end

    {status_id, severity_id, log_name} =
      case status do
        :failure ->
          {OCSF.status_failure(), OCSF.severity_high(), "sync.ingestor.failed"}

        :success ->
          {OCSF.status_success(), OCSF.severity_informational(), "sync.ingestor.succeeded"}
      end

    result_label = result || :success
    error_suffix = if error_message, do: " - #{error_message}", else: ""

    message =
      "Sync ingestion #{result_label} for #{source.name} (#{device_count} updates)#{error_suffix}"

    {status_id, severity_id, log_name, message}
  end

  defp classify_stage(_stage, _result, source, device_count, _error_message) do
    message = "Sync ingestion update for #{source.name} (#{device_count} updates)"
    {OCSF.status_success(), OCSF.severity_low(), "sync.ingestor.update", message}
  end

  defp build_observables(source) do
    [
      OCSF.build_observable(to_string(source.id), "Integration Source ID", 99),
      OCSF.build_observable(source.name, "Integration Source Name", 99)
    ]
  end

  defp build_unmapped(source, stage, result, device_count, error_message) do
    %{
      "integration_source_id" => to_string(source.id),
      "integration_source_name" => source.name,
      "source_type" => to_string(source.source_type),
      "stage" => to_string(stage),
      "result" => result && to_string(result),
      "device_count" => device_count,
      "error_message" => error_message,
      "agent_id" => source.agent_id,
      "gateway_id" => source.gateway_id,
      "partition" => source.partition
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
