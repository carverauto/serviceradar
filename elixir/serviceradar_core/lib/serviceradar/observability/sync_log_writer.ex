defmodule ServiceRadar.Observability.SyncLogWriter do
  @moduledoc """
  Writes integration sync lifecycle updates into the tenant OTEL logs table.
  """

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Observability.{Log, LogPromotion}

  require Logger

  @spec write_start(IntegrationSource.t(), keyword()) :: :ok | {:error, term()}
  def write_start(%IntegrationSource{} = source, opts \\ []) do
    write_log(source, :started, opts)
  end

  @spec write_finish(IntegrationSource.t(), keyword()) :: :ok | {:error, term()}
  def write_finish(%IntegrationSource{} = source, opts \\ []) do
    write_log(source, :finished, opts)
  end

  defp write_log(%IntegrationSource{tenant_id: nil}, _stage, _opts) do
    {:error, :missing_tenant_id}
  end

  defp write_log(%IntegrationSource{tenant_id: tenant_id} = source, stage, opts) do
    tenant_id_str = to_string(tenant_id)

    with {:ok, schema} <- resolve_schema(tenant_id_str) do
      attrs = build_log_attrs(source, stage, opts)

      Log
      |> Ash.Changeset.for_create(:create, attrs, tenant: schema)
      |> Ash.Changeset.force_change_attribute(:tenant_id, tenant_id_str)
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, log} ->
          LogPromotion.promote([log], tenant_id_str, schema)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e ->
      Logger.warning("Failed to write sync ingestion log: #{inspect(e)}")
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

  defp build_log_attrs(source, stage, opts) do
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
      attributes: build_attributes(source, stage, result, device_count, error_message),
      resource_attributes: %{}
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

  defp classify_stage(_stage, _result, source, device_count, _error_message) do
    message = "Sync ingestion update for #{source.name} (#{device_count} updates)"
    {"INFO", 9, message}
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
