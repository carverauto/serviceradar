defmodule ServiceRadar.Observability.SyncLogWriter do
  @moduledoc """
  Writes integration sync lifecycle updates into the schema OTEL logs table.
  """

  alias ServiceRadar.Events.InternalLogPublisher
  alias ServiceRadar.Events.OcsfEventPublisher
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Integrations.IntegrationSource

  require Logger

  @spec write_start(IntegrationSource.t(), keyword()) :: :ok | {:error, term()}
  def write_start(%IntegrationSource{} = source, opts \\ []) do
    write_log(source, :started, opts)
  end

  @spec write_finish(IntegrationSource.t(), keyword()) :: :ok | {:error, term()}
  def write_finish(%IntegrationSource{} = source, opts \\ []) do
    write_log(source, :finished, opts)
  end

  # The log goes to JetStream (`logs.internal.sync`); EventWriter stores and
  # promotes it like every other internal log.
  defp write_log(%IntegrationSource{} = source, stage, opts) do
    payload = build_log_payload(source, stage, opts)

    with :ok <- InternalLogPublisher.publish("sync", payload) do
      maybe_record_sync_failure_event(source, stage, opts)
    end
  rescue
    e ->
      Logger.warning("Failed to write sync ingestion log: #{inspect(e)}")
      {:error, e}
  end

  defp maybe_record_sync_failure_event(%IntegrationSource{} = source, :finished, opts) do
    result = Keyword.get(opts, :result)

    if result in [:failed, :timeout] do
      source
      |> build_failure_event_attrs(opts)
      |> OcsfEventPublisher.publish(family: :integration)
      |> case do
        {:ok, _event} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to record sync failure event: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  rescue
    error ->
      Logger.warning("Sync failure event recording failed: #{Exception.message(error)}")
      :ok
  end

  defp maybe_record_sync_failure_event(_source, _stage, _opts), do: :ok

  defp build_failure_event_attrs(%IntegrationSource{} = source, opts) do
    result = Keyword.get(opts, :result)
    device_count = Keyword.get(opts, :device_count, 0)
    error_message = Keyword.get(opts, :error_message)
    activity_id = OCSF.activity_log_update()
    severity_id = OCSF.severity_high()
    status_id = OCSF.status_failure()

    raw_data = %{
      "integration_source_id" => to_string(source.id),
      "integration_source_name" => source.name,
      "source_type" => to_string(source.source_type),
      "result" => to_string(result),
      "device_count" => device_count,
      "error_message" => error_message,
      "agent_id" => source.agent_id,
      "gateway_id" => source.gateway_id,
      "partition" => source.partition
    }

    %{
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      status_id: status_id,
      status: OCSF.status_name(status_id),
      status_code: "sync_ingestion_failed",
      status_detail: error_message,
      message: failure_event_message(source, result, device_count, error_message),
      metadata: OCSF.build_metadata(product_name: "Sync Ingestor"),
      observables: failure_event_observables(source),
      log_name: "serviceradar.sync",
      log_provider: "serviceradar_core",
      log_level: "error",
      raw_data: Jason.encode!(raw_data)
    }
  end

  defp failure_event_message(source, result, device_count, nil) do
    "Sync ingestion #{result} for #{source.name} (#{device_count} updates)"
  end

  defp failure_event_message(source, result, device_count, error_message) do
    "Sync ingestion #{result} for #{source.name} (#{device_count} updates): #{error_message}"
  end

  defp failure_event_observables(source) do
    Enum.reject(
      [
        observable(source.id, "Integration Source ID"),
        observable(source.name, "Integration Source"),
        observable(source.agent_id, "Agent ID"),
        observable(source.gateway_id, "Gateway ID")
      ],
      &is_nil/1
    )
  end

  defp observable(value, _name) when value in [nil, ""], do: nil

  defp observable(value, name) do
    %{"name" => name, "type" => "string", "value" => to_string(value)}
  end

  defp build_log_payload(source, stage, opts) do
    result = Keyword.get(opts, :result)
    device_count = Keyword.get(opts, :device_count, 0)
    error_message = Keyword.get(opts, :error_message)
    time = Keyword.get(opts, :time, DateTime.utc_now())

    {severity_text, severity_number, body} =
      classify_stage(stage, result, source, device_count, error_message)

    %{
      timestamp: time,
      severity_text: severity_text,
      severity_number: severity_number,
      body: body,
      service_name: "serviceradar.core",
      scope_name: "sync_ingestor",
      attributes: build_attributes(source, stage, result, device_count, error_message)
    }
  end

  defp classify_stage(:started, _result, source, device_count, _error_message) do
    message = "Sync ingestion started for #{source.name} (#{device_count} updates)"
    {"INFO", 9, message}
  end

  defp classify_stage(:finished, result, source, device_count, error_message) do
    failure = result in [:failed, :timeout]
    severity_text = if failure, do: "ERROR", else: "INFO"
    severity_number = if failure, do: 17, else: 9
    result_label = result || :success
    error_suffix = if error_message, do: " - #{error_message}", else: ""

    message =
      "Sync ingestion #{result_label} for #{source.name} (#{device_count} updates)#{error_suffix}"

    {severity_text, severity_number, message}
  end

  defp build_attributes(source, stage, result, device_count, error_message) do
    %{
      "serviceradar" => %{
        "sync" => %{
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
      }
    }
  end
end
