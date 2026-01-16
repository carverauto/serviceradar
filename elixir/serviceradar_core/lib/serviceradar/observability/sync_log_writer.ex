defmodule ServiceRadar.Observability.SyncLogWriter do
  @moduledoc """
  Writes integration sync lifecycle updates into the tenant OTEL logs table.
  """

  alias ServiceRadar.Actors.SystemActor
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

  defp write_log(%IntegrationSource{} = source, stage, opts) do
    # Simple actor - DB connection's search_path determines the schema
    actor = SystemActor.system(:sync_log_writer)
    attrs = build_log_attrs(source, stage, opts)

    Log
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create()
    |> case do
      {:ok, log} ->
        LogPromotion.promote([log])
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("Failed to write sync ingestion log: #{inspect(e)}")
      {:error, e}
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
